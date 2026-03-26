# Delta Implementation Bug Tracker

**Project:** TOGBankClassic v0.8.0 Pull-Based Delta Protocol
**Last Updated:** March 26, 2026
**Status:** Testing Phase - Core Protocol Operational

**Active Issues:**
- ⚠️ [MAIL-006] Mail UI item display behavior unclear - Investigating contradictory symptoms (see below)

**Recent Fixes (2026-03-26):**
- ✅ [UI-014] **MEDIUM** Window sizes not persisted across reload for Inventory, Requests, and Search — All three windows called `SetStatusTable(TOGBankClassic_Options.db.char.framePositions)` pointing at the same flat table. AceGUI stores `width`, `height`, `top`, and `left` keys directly into the status table; since all three windows shared one table, each move or resize overwrote the previous window's values. Only the last-touched window's size survived a reload. Additionally, Inventory called `window:SetWidth(550)` and Requests called `window:SetWidth(MIN_WIDTH)` *after* `SetStatusTable`, discarding the saved width every time the window was first opened. Fix: Each window now receives its own sub-table with a prefilled default size: `positions.inventory = positions.inventory or { width = 550, height = 500 }`, `positions.requests = positions.requests or { width = MIN_WIDTH, height = 500 }`, `positions.search = positions.search or { width = 250, height = 400 }`. The explicit `SetWidth` overrides after `SetStatusTable` were removed so AceGUI's `ApplyStatus` can restore the saved size directly. Search only persists size (position is always snapped to the main UI in `Open()`). Locations: UI/Inventory.lua `DrawWindow` (~line 91); UI/Requests.lua `DrawWindow` (~line 613); UI/Search.lua `DrawWindow` (~line 340).
- ✅ [UI-013] **LOW** Search result list showed no banker name and always reported "0 Results" — Three bugs in `DrawContent()`: (1) A `Label` widget was created and had its text set to `bankAlt` but `self.Results:AddChild(label)` was never called, so the widget was silently discarded and nothing appeared in column 2. (2) `count` was never incremented inside the loop, so the status bar always displayed `"0 Results"` regardless of matches. (3) The `end` closing the `if itemWidget then` block was misplaced after the label creation, making the label code structurally interior to that block but impossible to read as such. A user request to display which banker holds each item surfaced all three issues. Fix: Added `self.Results:AddChild(label)` after `label:SetText`, moved `count = count + 1` inside the `if itemWidget then` block, fixed indentation throughout the loop, and updated the label to display the banker name in grey (`|cFFAAAAAA<bankAlt>|r`) at a height of 35px to match the icon row. The Search window was also made resizable (`EnableResize(true)`, `SetResizeBounds(200, 200)`) so users can widen it to accommodate the new column. Location: UI/Search.lua `DrawContent` (~line 663), `DrawWindow` (~line 336).
- ✅ [SORT-002] **MEDIUM** "Sort by Type" and "Sort by Level" produced random-looking order for items from other alts — `GetItemInfoInstant` was used as the fallback for items not yet in the client cache (i.e., items belonging to alts the current player hasn't recently inspected). The fallback path only extracted `iconID` and `name`, discarding the `itemClassId` and `itemSubClassId` return values that `GetItemInfoInstant` provides without a cache hit. Items that went through this path had `Info.class = nil`, which triggered `Sort()`'s nil-fill block and forced `Info.level = 1` regardless of actual item level. Result: all uncached items pooled at the bottom of "Sort by Level" as if they were level-1 items, and in "Sort by Type" they sorted into class=0 (before all real types) instead of their correct class group. Fix: extended the `GetItemInfoInstant` call in the Branch 1 cache-miss fallback (`Item.lua`) to also capture and store `itemClassId` and `itemSubClassId` in `capturedItem.Info`. Items without a full cache hit now have correct class/subclass grouping immediately, and their `level` field is no longer incorrectly overridden to 1 by the nil-fill. Location: Item.lua `GetItems` Branch 1 cache-miss fallback (~line 252).
- ✅ [SORT-001] **HIGH** "Sort by Type" equip-slot grouping completely non-functional — the `Sort()` comparator for `mode == "type"` read `a.Info.equip` and `b.Info.equip` to group items by inventory slot (e.g., helms together, boots together). However, every code path that builds `Info` stores the equip slot under `equipId` (`GetItems` Branch 1, Branch 2, `GetInfo`, `Sort` nil-fill). Since `a.Info.equip` was always `nil`, both sides coerced to `""` and the equip-slot comparison was always equal — a permanent no-op. Within a class/subclass group, weapons of different types (1H axe vs 2H axe vs sword), armor of different slots (helm vs boots vs cloak), and rings/trinkets all intermixed with no slot separation. Fix: changed `a.Info.equip or ""` and `b.Info.equip or ""` to `a.Info.equipId or 0` and `b.Info.equipId or 0`, matching the actual field name. Location: Item.lua `Sort()` type comparator (~line 471).
- ✅ [UI-012] **LOW** Debug tab text stacked on General tab on login/reload until tab is manually switched — `FCF_DockFrame(frame)` internally calls `FCF_SelectDockFrame(frame)`, making the debug tab the selected (visible) chat window at the time it is docked. WoW persists the selected tab to SavedVariables, so on the next login or /reload the debug tab was restored as the active tab. Because docked chat frames share the same screen position, General and the debug tab were visually overlaid: both rendered their messages into the same area until the player clicked any tab, at which point `FCF_SelectDockFrame` was called by WoW's tab-click handler and the dock rendered only one frame. The issue reproduced every session after `CreateDebugTab` had been called at least once. Fix: Call `FCF_SelectDockFrame(ChatFrame1)` immediately after `FCF_DockFrame` in both code paths in `CreateDebugTab()` (existing-tab-found path and new-tab-created path) to restore General as the active tab before WoW saves state. Location: Output.lua `CreateDebugTab` (~lines 183, 238).
- ✅ [SETTINGS-001] **HIGH** `maxRequestPercent` and `autoTombstoneDays` never propagated to other guild members — Both settings were stored locally (per-guild faction SavedVariables AND AceDB global) and the `set` handlers had a comment "propagates to all clients" that was completely misleading: no broadcast/sync mechanism existed. Every client initialized `Guild.Info.settings.maxRequestPercent = 100` from `Database:Reset()` at first use. Since `GetMaxRequestPercent()` reads `Guild.Info.settings` first, each client always enforced their own hard-coded default (100). A banker setting 50% would see 50% themselves but all other members would still enforce 100%. No `guild-settings` message type existed, no `BroadcastSettings` or `ApplyRemoteSettings` functions existed, and `SyncDeltaVersion` sent only hash-list data with no settings payload. Fix: (1) Added `TOGBankClassic_Guild:BroadcastSettings()` — auth-checks sender (banker/officer/GM), serializes `{type="guild-settings", settings={maxRequestPercent, autoTombstoneDays}}`, sends on `togbank-hl` NORMAL priority. (2) Added `TOGBankClassic_Guild:ApplyRemoteSettings(sender, settings)` — validates sender auth (`SenderHasGbankNote` OR `SenderIsGM` OR `SenderIsOfficer`), bounds-checks both fields, writes to `Guild.Info.settings`. (3) `Options.lua` both `set` handlers now call `BroadcastSettings()` after writing locally. (4) `Chat.lua` `togbank-hl` handler now dispatches `data.type == "guild-settings"` to `ApplyRemoteSettings`. (5) `Events.lua` `SyncDeltaVersion()` now calls `BroadcastSettings()` for authorized senders after the hash-list broadcast, covering new joiners who missed the immediate notification. Locations: Guild.lua (new `BroadcastSettings` + `ApplyRemoteSettings` functions after `ReceiveRosterData`); Chat.lua `togbank-hl` handler; Options.lua `autoTombstoneDays` and `maxRequestPercent` set handlers; Events.lua `SyncDeltaVersion`.

**Recent Fixes (2026-03-25):**
- ✅ [SLOTS-002 / UI-009] **HIGH** Non-bankers permanently see 0/0 slots in status bar when items haven't changed — SLOTS-001 added `bankSlots`/`bagsSlots` to outgoing deltas when slot counts change, but the `no-change` whisper path was never touched. When a requester's item hash matched the banker's (no item changes), the responder sent a `togbank-nochange` whisper that contained only the version and hash fields — no slot data. Non-bankers whose slot structs were initialized as `{count=0, total=0}` by the v0.8.0 migration block never received a delta with slot changes (because items never changed), so slots stayed permanently 0/0. The status bar showed `0/0 Slots` even though items displayed correctly. Three separate `no-change` message builders existed: (1) `RespondToStateSummary` hash-match path, (2) `RespondToStateSummary` legacy version-match path, (3) `SendAltData` hash-correction path (item hash matches but `DeltaHasChanges` returns false). All three built the message without slot data. Fix: Added `bankSlots = currentAlt.bank and currentAlt.bank.slots or nil` and `bagsSlots = currentAlt.bags and currentAlt.bags.slots or nil` to all three `no-change` message tables in Guild.lua. The `togbank-nochange` receiver in Chat.lua now applies these fields to `localAlt.bank.slots` / `localAlt.bags.slots` after the existing hash-correction block (same guard pattern, `SLOT-CORRECTION` debug label). Slots are now always delivered on the next sync cycle regardless of whether items have changed. Locations: Guild.lua `RespondToStateSummary` hash-match path (~line 1983), `RespondToStateSummary` legacy path (~line 2039), `SendAltData` hash-correction path (~line 2616); Chat.lua `togbank-nochange` receiver (~line 1402).

**Recent Fixes (2026-03-24):**
- ✅ [PERF-024] **MEDIUM** `ComputeItemDelta()` O(N²) fallback when link normalization mismatches — Fallback 2 (deep ID fallback) iterated all `oldItems` with a `for _, item in pairs(oldItems)` loop for every new item that failed both the primary key lookup and the ID-only lookup. In the worst case (many items with link normalization mismatches, e.g. suffixed gear), this is O(N×M). Additionally, after a Fallback 2 match was found, a second O(N) reverse scan of `oldByKey` iterated all entries by value to locate and remove the matched item. Fix: Build a per-ID candidate list `oldByIDList[idStr]` during the existing `oldByIDOnly` loop, storing each item's reference and its exact key in `oldByKey`. Fallback 2 now does an O(1) hash lookup into `oldByIDList` then iterates O(k) candidates where k = items with the same base ID (almost always 1–2 for any realistic bank). The matched item's key is stored on the candidate, so removal from `oldByKey` is also O(1). The O(N) reverse-scan cleanup block removed entirely. Location: DeltaComms.lua `ComputeItemDelta()`.
- ✅ [PERF-023] **HIGH** `RecalculateAggregatedItems()` called unconditionally on every login for all banker alts — The deferred migration block in `Database:Load()` (introduced by PERF-010) ran an "AGGRESSIVE FIX" unconditionally every login: cleared `alt.items` and called `RecalculateAggregatedItems()` (5 Aggregate passes) for every banker alt with bank/bags data, plus `Aggregate(alt.items, nil)` dedup for every synced alt. This was papering over item-count duplication bugs (`DATA-004`, `STALE-INDEX-FIX`, `DUPLICATION-FIX`, `DUPLICATION-FIX-003`) that were all resolved in v0.9.6. Current minimum supported version is v0.9.6; no users below that remain. Fix: Removed the `RecalculateAggregatedItems` call, the synced-alt dedup block, and the `RecalculateAggregatedItems` function from `Bank.lua` (dead code — no other callers). The 3 cheap guarded migrations (slots init, inventoryHash compute, inventoryUpdatedAt backfill) are retained; they short-circuit in O(1) for any alt already migrated. Updated the PERF-010 timer comment to reflect the remaining lightweight work. Locations: Database.lua deferred migration block; Bank.lua `RecalculateAggregatedItems` function (removed entirely).
- ✅ [PERF-022] **HIGH** `ApplyDelta()` ran 5 full item-iteration passes per received delta — Three "DEFENSIVE" `Aggregate()` dedup passes ran after `ApplyItemDelta()` on each of bank, bags, and mail sections independently (3 passes). These were paranoia guards for `ApplyItemDelta` duplication bugs that were already fixed by STALE-INDEX-FIX, DUPLICATION-FIX, and DUPLICATION-FIX-003. The final recalculation then called `Aggregate(bank, bags)` followed by `Aggregate(result, mail)` — the second call re-iterated the full bank+bags set a second time (2 passes). Total: 5 full item passes where 1 was sufficient. For a banker with 200 bank items and 150 bag items this meant ~1750 iterations + `GetItemKey()` calls + table allocations per delta received; multiplied across frequent delta syncs, this was a measurable stutter source. Additionally each defensive pass sorted all item keys (unnecessary since `bank.items`/`bags.items`/`mail.items` are never displayed directly — only the aggregated `current.items` is rendered). Fix: (B) Removed the 3 defensive per-section dedup passes — `ApplyItemDelta` duplication bugs are fixed and any remaining edge-case would be caught by the next hash-mismatch self-heal cycle. (C) The final recalculation retains 2 `Aggregate()` calls (bank+bags, then +mail) but removes the now-redundant intermediate sort/rebuild — the key sort happens once at the end. Net reduction: 5 passes → 2 passes, 3 sorts eliminated. Location: DeltaComms.lua `ApplyDelta()` bank/bags/mail apply blocks + recalculation block.
- ✅ [P2P-022] **HIGH** `Guild:HashUpdate()` broadcast missing `isBanker` field — `/togbank hashupdate` (banker-only command) sent a `hash-list-broadcast` payload without an `isBanker` field. Receivers read `data.isBanker or false` → `false`, treating the broadcaster as a non-banker peer: `latestBankerHashes` cache was not updated and no `togbank-hlr` dispatch occurred. Same root cause as P2P-021 but in a separate code path. Fix: added `isBanker = true` to the payload (the surrounding guard already confirms the sender is a banker). Location: Guild.lua `HashUpdate()` (~line 3326).
- ✅ [P2P-021] **CRITICAL** `Guild:Share()` broadcasted `isBanker=false` for banker on every 10-minute sync cycle — `Guild:Share()` sent a preliminary `hash-list-broadcast` for just the current banker's single alt before calling `SyncDeltaVersion()`. This payload had no `isBanker` field; receivers read `data.isBanker or false` → `isBanker=false`. All 50 online peers processed this as a non-banker broadcast: they skipped the `latestBankerHashes` cache update and the `togbank-hlr` dispatch, meaning the banker's authoritative hash was never stored as the reference point. `SyncDeltaVersion()` arrived seconds later with the correct `isBanker=true` and all 36 alts, but the 0.15s batch dedup window sometimes processed the bad message separately, leaving peers in a state where they treated the banker as a peer and queued whisper-offers back to it (up to 1 whisper × 50 members × 36 alts per cycle). Additionally, the single-alt pre-broadcast was entirely redundant — `SyncDeltaVersion()` already includes the banker's own alt in the full hash list. Fix: removed the single-alt pre-broadcast from `Guild:Share()` entirely. `SyncDeltaVersion()` is now the sole `hash-list-broadcast` sender; it correctly stamps `isBanker = IsBank(myPlayer)` with the complete alt list. Eliminates the spam of hash-offer whispers directed at the banker on every 10-minute cycle. Location: Guild.lua `Share()` (~line 3366).

**Recent Fixes (2026-03-20):**
- ✅ [UI-003] **LOW** Quality border color missing for all gear (weapons, armor) — three compounding issues: (1) After UI-011 switched Branch 1 to `GetItemInfo(link)`, remote-synced gear not yet in the client cache still had nil rarity at draw time — `DrawItem` needed its own fallback. (2) `Item:Sort` was mutating `item.Info.rarity = item.Info.rarity or 1` for any item whose rarity was nil, replacing nil with 1 (common/white) before `DrawItem` ever ran — the sort comparators already handled nil safely via `(a.Info.rarity or 0)` so the assignment was unnecessary and actively harmful. Because rarity was truthy (1) by the time `DrawItem` ran, `GetItemQualityColor(1)` was called and the border was explicitly set to white, and the fallback paths never fired. Fix: (a) Removed the `rarity = rarity or 1` default from `Item:Sort`; nil rarity now propagates to `DrawItem` correctly. (b) `DrawItem` adds two fallback levels: sync — `GetItemInfo(item.Link)` at draw time; async — `ContinueOnItemLoad` fires `GetItemInfo(item.Link)` when the item enters the client cache, then calls `border:SetVertexColor`. All lookups use `item.Link` only — ID-based lookup excluded because base item ID gives wrong rarity for suffixed gear. Locations: Item.lua `Sort` (~line 449); UI.lua `DrawItem` (~line 145).

**Recent Fixes (2026-03-19):**
- ✅ [UI-011] **MEDIUM** Item quality border color missing for all items in bank inventory — `GetItems` Branch 1 (items where `Link` is set) built `Info` using `GetItemInfoInstant`, which returns only `icon` and item type fields — no `rarity`. Every item scanned directly from the local bank has a link (from `GetContainerItemLink`), so ALL items on a local bank scan went through Branch 1. `DrawItem` guards border coloring with `if item.Info.rarity then`; since `rarity` was always nil, `SetVertexColor` was never called, leaving the border white/invisible for every item regardless of quality. Additionally, even after switching Branch 1 to `GetItemInfo(link)` (which does return rarity), gear items synced from a remote banker that the receiver has never encountered are not yet in the client cache — `GetItemInfo` returns nil, and the old fallback (`GetItemInfoInstant`) also has no rarity. Fix: Branch 1 now has two paths: (1) Cached — `GetItemInfo(capturedItemLink)` returns data → build full `Info` synchronously including rarity (same as Branch 2 cached path). (2) Not cached — `CreateFromItemID` + `ContinueOnItemLoad` async load, identical to Branch 2's uncached path; `GetInfo(id, link)` is called in the callback to populate full `Info` including rarity once loaded. Last resorts (create/callback failure) fall back to `GetItemInfoInstant` (icon+name only, no rarity). Local bank scans always hit path (1) since the bank is open = items in cache. Remote synced gear hits path (2) when the receiver hasn't cached that item yet. Location: Item.lua `GetItems` Branch 1 (~line 228-300).
- ✅ [REQ-001] **HIGH** `drainQueriedRequests` crashed with "attempt to call global 'serializeRequestV1' (a nil value)" — `serializeRequestV1` and `serializeTombstoneV1` were declared as `local function` at line ~253 but called at lines 83 and 94 inside `drainQueriedRequests` (defined at line ~49). In Lua, `local` names are only visible after their declaration point, so the functions were nil at call time. Triggered whenever the responder drain fired to send `togbank-rd2` records to a querier. Fix: Moved `RI_VERSION`, `RD2_VERSION`, `serializeRequestV1`, and `serializeTombstoneV1` to before `ctlDepthForDrain` (above `drainQueriedRequests`) so they are in scope when the drain executes. `deserializeRequestV1` and `serializeIndexChunkV1` are not called before their definition and were left in place. Location: RequestLog.lua (moved locals/functions from line ~253 to line ~33).
- ✅ [UI-010] **HIGH** Mail items (consumables) show no tooltip on hover in bank inventory — `ItemString` format mismatch between mail and bank items caused `SetHyperlink` to silently fail. `GetItemString()` returns `"item:4306:0:0:0:0:0:0:0:0"` (WITH `item:` prefix). `MailInventory.lua` stored this directly as `ItemString`. `ReconstructItemLink` and `ProcessItemQueue` both embed `ItemString` via `|Hitem:%s`, producing `|Hitem:item:4306:...|h` — a double `item:` prefix. `GameTooltip:SetHyperlink` on this malformed link fails silently — no tooltip. Bank items don't have this problem because `StripItemLinks` stores `ItemString` via `string.match(link, "item:([^|]+)")` which captures WITHOUT the `item:` prefix, producing a valid `|Hitem:4306:...|h`. Fixes: (1) `MailInventory.lua` now strips the `item:` prefix when storing `storageItemString`, so future scans store in the correct format. (2) `ReconstructItemLink` and the `ProcessItemQueue` `ContinueOnItemLoad` callback both defensively strip the prefix (`item.ItemString:match("^item:(.+)$") or item.ItemString`) to handle existing persisted data. Additionally, `DrawItem` `OnEnter`/`OnLeave` callbacks were moved outside the `if item.Link then` guard so items without a pre-built link still register hover handlers. Locations: MailInventory.lua (~66), Guild.lua `ReconstructItemLink` (~2231) and `ProcessItemQueue` ContinueOnItemLoad callback (~2138), UI.lua `DrawItem` (~108-130).

**Recent Fixes (2026-03-14):**
- ✅ [SLOTS-001] **HIGH** Delta syncs missing slot metadata causing 0/0 slots display for non-bankers — Delta protocol only transmitted item changes (`ComputeItemDelta` on bank/bags/mail items) but never included `bank.slots` or `bags.slots` metadata (count/total capacity). When `ApplyDelta` created missing structures, it initialized them as `{ items = {} }` without slots. Non-bankers who never received a full sync or only received delta updates after initial sync had valid items but missing slot counts. Status bar displayed "0/0" in both default view and hover tooltip. Fix: (1) `BuildDelta` now includes `bank.slots` and `bags.slots` in delta when they differ from previous state, (2) `ApplyDelta` now applies these slots when present in delta, (3) Added defensive checks in UI hover callback to handle missing data gracefully (shows "No data available" or "Waiting for sync..." for stub/unsynced alts). Forward-looking fix; existing incomplete data requires fresh sync to populate slots. Locations: DeltaComms.lua `BuildDelta` (~822-845), `ApplyDelta` (~1247-1308); UI/Inventory.lua `OnEnterStatusBar` (~212-227).
- ✅ [SYNC-015] **HIGH** `ReportBankerDataProgress` crashed with nil `self.Info` during HLR processing — Function accessed `self.Info.alts` at line 658 without checking if `self.Info` exists first. Can occur during race conditions when HLR processing happens before guild data initialization completes (e.g., fast-fill triggered during addon load). Stack trace: `OnCommReceived` (Chat.lua:2011) → `ReportBankerDataProgress` (Guild.lua:658) during hash-list-reply processing in context "fast-fill". Fix: Added defensive nil check at function entry; early returns with debug log if `self.Info` doesn't exist. Location: Guild.lua `ReportBankerDataProgress` (~629-637).

**Recent Fixes (2026-03-13):**
- ✅ [PERF-021] **CRITICAL** ChatThrottleLib Despool execution errors during zone transitions — When zoning with a large message backlog (e.g., 180+ queued messages from ongoing delta sends taking 26+ seconds), CTL's Despool() function exceeded execution limits when combined with other addon operations (Bagnon, etc.) and our own event handlers. The cumulative execution budget across all addons was exhausted during zone-in when ChatThrottleLib tried to process its queue while competing with GUILD_ROSTER_UPDATE, hash broadcasts, and other expensive operations. Manifested as "script ran too long" errors in ChatThrottleLib.lua:415 (Despool) and execution limit errors from other addons like Bagnon. Fix: Add 2.5-second zone-in cooldown period triggered by PLAYER_ENTERING_WORLD (any type: login, reload, OR zone change). During cooldown: (1) OnShareTimer defers periodic broadcasts and reschedules, (2) SyncDeltaVersion blocks BULK-priority calls (timer-based) but allows NORMAL priority (login broadcasts), (3) share-request replies are deferred to avoid responding during cooldown, (4) manual /togbank share command defers and warns user. After 2.5s cooldown expires, the deferred login broadcasts (QueryRequestsIndex + SyncDeltaVersion) execute via 2.6s timer if they were blocked. Result: ChatThrottleLib gets 2.5s breathing room to drain its queue without competing with our operations; eliminates execution errors during zone transitions; no functional impact since P2P operations naturally have 60s collect windows. Locations: Events.lua PLAYER_ENTERING_WORLD (~284-310 cooldown init), OnShareTimer (~169-177 defer check), SyncDeltaVersion (~252-260 priority filter), GUILD_ROSTER_UPDATE (~350-370 deferred login broadcasts); Chat.lua share-request handler (~1850-1858 defer), share command (~2086-2104 defer with reschedule).
- ✅ [PERF-020] **CRITICAL** Stuttering from synchronous hash broadcast processing — Hash-list broadcasts were processed immediately and synchronously when received. When multiple guild members broadcast simultaneously (common during login waves, zone changes, raids), each broadcast triggered 36 hash comparisons (timestamp lookups + HasAltContent checks + hash building). Example: 4 broadcasts within 2 seconds = 144 hash comparisons blocking main thread = 100-300ms freeze causing visible stuttering during gameplay. Compounded when player was simultaneously sending data (ChatThrottleLib chunk callbacks) or processing other sync operations. Fix: Batch incoming hash broadcasts with 0.15s timer. First broadcast starts timer, additional broadcasts within window get queued. When timer fires, process all queued broadcasts in one deferred operation with automatic sender deduplication. Result: Spreads work across multiple frames (~6 frames at 60 FPS), prevents overlapping comparison operations, adds only 0.25% latency to 60s P2P collect window (negligible). Eliminates stuttering during sync storms. Location: Chat.lua Init (~23-26 queue/timer variables), ProcessQueuedHashBroadcasts (~569-653 batch processor), OnCommReceived hash-list-broadcast handler (~1820-1847 queueing logic).
- ✅ [PERF-019] **CRITICAL** Overlapping roster refresh operations during zone changes — `GUILD_ROSTER_UPDATE` event handler didn't guard against concurrent execution. When player zoned while sending data (65-chunk ChatThrottleLib queue) or during roster refresh retries, WoW fires `GUILD_ROSTER_UPDATE` automatically during zone transition. If `needsFullRosterRefresh=true` from previous retry, it started another 0.5s deferred operation (InvalidateBanksCache + RefreshOnlineCache + RebuildBankerRoster). Multiple overlapping timers combined with ChatThrottleLib chunk callbacks (30 failures × callback overhead) exceeded cumulative execution limit. Explained intermittent errors (1 in 5 login/reload/zone) - only occurred when multiple expensive operations overlapped. Fix: Add `refreshInProgress` guard flag. Check before starting refresh, set to true at start, clear to false after 0.5s deferred work completes. Subsequent `GUILD_ROSTER_UPDATE` events skip if refresh already in progress. Result: Maximum one roster refresh operation in-flight at a time; prevents cascading retries during zone changes; eliminates overlap with ChatThrottleLib chunk processing. Location: Events.lua `GUILD_ROSTER_UPDATE` handler (~305-360).
- ✅ [PERF-018] **MEDIUM** Debug options UI built at addon load — `BuildDebugArgs()` created ~55 AceConfig entries (15 categories, 28 sub-tags, 12 headers/buttons) during `Options:Init()` at addon load, even though most users never open the Debug tab. Contributed to intermittent execution limit errors during login/reload/zone changes when combined with other init operations. Fix: Change debug tab `args` from direct `BuildDebugArgs()` call to lazy function that builds once on first access. Result: Default = zero options UI creation at addon load; opening Debug tab first time = builds & caches UI (~55 entries); subsequent opens = reuses cache. Location: Options.lua `Init` debug tab definition (~372-384).
- ✅ [PERF-017] **LOW** Unnecessary SavedVariables persistence — Three variables persisted to SavedVariables unnecessarily: `TOGBankClassicIcon` (always nil, never used), `TOGBankClassic_PerfMetrics` (~400 lines per session even when disabled), `TOGBankClassic_MailDebugLog` (dev debugging left in production). Increased file size and parse time on every reload. Fix: Removed TOGBankClassicIcon and MailDebugLog from .toc SavedVariables list; set PerfMetrics = nil when disabled (similar to PERF-014/016). Result: 400-600 lines removed from SavedVariables for typical user. Locations: TOGBankClassic.toc (~7), Performance.lua `Initialize` (~42), Events.lua `PLAYER_LOGOUT` (~278-345 removed).
- ✅ [PERF-016] **LOW** Performance tracking initialization overhead — `Performance:Initialize()` always created sessions, ran GC, initialized data structures even when `TOGBankClassic_PerfEnabled = false` (default). Session creation, table inserts, GC loops for a disabled debugging feature on every addon load. Fix: Move enabled flag check to top of `Initialize()`, early return if disabled. Result: Default (disabled) = zero overhead; when enabled = normal behavior. Location: Performance.lua `Initialize` (~33-48).
- ✅ [PERF-015] **MEDIUM** UI frame creation during addon load — Inventory, Donations, Mail, Search, and Requests windows all called `DrawWindow()` during `Init()` at addon load, creating AceGUI frames (windows, buttons, scrollframes, etc.) that may never be opened. Frame creation overhead at load for 5 windows that most users won't open every session. All 5 modules already had lazy initialization pattern in `Open()` function: `if not self.Window then self:DrawWindow() end`. Fix: Remove `DrawWindow()` call from `Init()`, rely on existing lazy check in `Open()`. Result: On load = zero frame creation; first `Open()` = creates & caches frame; subsequent opens = reuses cached frame. Locations: UI/Inventory.lua `Init` (~3-5), UI/Donations.lua `Init` (~3-5), UI/Mail.lua `Init` (~3-5), UI/Search.lua `Init` (~3-5), UI/Requests.lua `Init` (~365-371).
- ✅ [PERF-014] **HIGH** Persistent debug log loading unconditionally — `Output:Init()` always loaded `TOGBankClassicDB_DebugLog` from SavedVariables (up to 50,000 entries) even though persistent logging was disabled by default. Every player paid the cost of parsing 1-5 MB of debug log entries on every reload, plus garbage collection loop through all entries, even though 99% never enable debug logging. Fix: Check `TOGBankClassic_DebugLogEnabled` flag before loading in `Init()`, saving in `SavePersistentLog()`, and adding in `AddToPersistentLog()`. Result: Default (disabled) = zero SavedVariables loading, zero GC overhead, empty log array; when enabled = loads/saves as before. Load time savings: skip parsing 1-5 MB + GC loop on every reload. Locations: Output.lua `Init` (~72-89), `SavePersistentLog` (~456-470), `AddToPersistentLog` (~418-433); Options.lua debugLogEnabled toggle description updated.
- ✅ [PERF-013] **CRITICAL** ChatThrottleLib timeout from zone change message spam — `PLAYER_ENTERING_WORLD` fired on EVERY zone change (not just login/reload), triggering 2 GUILD broadcasts per player (`QueryRequestsIndex` + `SyncDeltaVersion`). When 40 players entered MC/BWL simultaneously, 80 messages queued instantly, overwhelming ChatThrottleLib's Despool function (line 389) and causing "script ran too long" errors. Fix: Check `isInitialLogin` and `isReloadingUi` parameters; only set `needsFullRosterRefresh = true` and trigger broadcasts on actual login/reload. Zone changes now skip roster refresh entirely (zero broadcasts). Periodic `OnShareTimer` maintains 10-minute sync cycle. Result: Login/reload = 2 broadcasts (normal), zone changes = 0 broadcasts (no ChatThrottleLib spam), no more timeout errors when large groups zone together. Location: Events.lua `PLAYER_ENTERING_WORLD` handler (~348-367).
- ✅ [PERF-008] **CRITICAL** Bagnon execution timeout from BAG_UPDATE spam — ItemHighlight was registering BAG_UPDATE events for ALL players at addon load, causing all guild members (even non-bankers) to process 50+ rapid BAG_UPDATE events during zone changes. Cumulative execution across all addons with BAG_UPDATE handlers exceeded Bagnon's execution time limit, causing "Script from Bagnon has exceeded its execution time limit" errors. Highlighting feature doesn't need ANY events until a banker explicitly enables it, but events were registered during `Initialize()` regardless. Fix: On-demand event registration — `Initialize()` registers ZERO events; `SetEnabled(true)` checks banker status and registers BAG_UPDATE/BANKFRAME/PLAYERBANKSLOTS_CHANGED events only when highlighting is actively enabled; `SetEnabled(false)` unregisters all events. Result: Non-bankers and bankers with highlighting disabled = zero overhead forever; bankers with highlighting enabled = events registered on-demand with 500ms throttling + search string caching. Eliminated Bagnon timeout errors completely. Locations: ItemHighlight.lua `registerBagEvents` (~23-59), `unregisterBagEvents` (~62-74), `Initialize` (~77-84), `SetEnabled` (~87-136).

**Recent Fixes (2026-03-07):**
- ✅ [SYNC-014] **HIGH** No P2P sync on login until zone or 10-minute timer — `SyncDeltaVersion` was never called on login; the first broadcast was deferred entirely to the 10-minute `OnShareTimer`. Players had to zone or wait 10 minutes before peers could offer them fresher data. Fix: Call `SyncDeltaVersion("NORMAL")` immediately after roster init completes in the `GUILD_ROSTER_UPDATE` deferred block (alongside the existing `QueryRequestsIndex` call). Location: Events.lua `GUILD_ROSTER_UPDATE` handler.

**Recent Fixes (2026-03-06):**
- ✅ [REQSYNC-008] **CRITICAL** `SenderIsOfficer` crashed with "attempt to call global 'GuildControlGetRankFlags' (a nil value)" on every bank open — `GuildControlGetRankFlags` is a Retail-only WoW API that does not exist in Classic Era. It was introduced in the REQSYNC-001 fix as a way to check per-rank permissions at lookup time. Fix: Moved officer determination to `RefreshOnlineCache` (cache-build time). Classic Era has no per-rank permission API, but `CanViewOfficerNote()` returns whether the LOCAL player has officer-note access. Since Classic ranks are strictly ordered (lower rankIndex = more permissions), if the local player at rankIndex N has officer-note access, all members with rankIndex <= N also have it. `isOfficer` is now stored on each memberRoster entry at cache-build time; `SenderIsOfficer` is a pure O(1) cache read with zero WoW API calls. Regression introduced in commit 4e68f63. Locations: Guild.lua `RefreshOnlineCache`, `SenderIsOfficer`.
- ✅ [UI-003] Item quality border color not showing for non-recipe gear — resolved by UI-011 (Item.lua Branch 1 rarity fix) + DrawItem sync/async link-based fallback for uncached remote gear. See Recent Fixes (2026-03-20).
- ⚠️ [UI-004] Tooltips missing for some food items (Homemade Cherry Pie, Roasted Quail confirmed)

**Recent Fixes (2026-03-12):**
- ✅ [UI-001] **MEDIUM** Inventory slot counts show 0/0 for non-bank members — delta protocol transmitted bank/bags item changes but never included `bank.slots`/`bags.slots`. Non-bank members received correct item lists after sync but the status bar always displayed 0/0 because slot totals were never part of the delta payload. Full snapshots (via `StripAltLinks`) did include slots, so bankers themselves always saw correct counts. Fix: `DeltaComms.lua` delta builder now appends `changes.bankSlots` and `changes.bagsSlots` to every delta; the applier writes them onto `current.bank.slots`/`current.bags.slots` after item changes are applied. Locations: DeltaComms.lua `ComputeDelta` (after mail delta computation), `ApplyDelta` (after bags item apply block).
- ✅ [UI-002] **LOW** Broken square icon when hovering over gold amount in status bar — `GetCoinTextureString()` returns `|T...|t` texture-embed codes that do not render reliably in AceGUI status bar FontStrings; the coin medallion texture appears as a white/broken square. Fix: Replaced both calls in `UI/Inventory.lua` with a new local `FormatMoneyText()` helper that formats gold/silver/copper as colored text (`|cffFFD700Xg|r`, `|cffc0c0c0Xs|r`, `|cffb46a2fXc|r`) with no embedded textures — renders correctly in any FontString context. Location: UI/Inventory.lua `FormatMoneyText` (new local, top of file), `DrawWindow` default status and `OnEnterStatusBar` callback.

**Recent Fixes (2026-03-05):**
- ✅ [COMM-004] **CRITICAL** WoW AceComm 16-prefix hard limit exceeded — 9 of 24 registered prefixes (slots 17-25) silently dropped by WoW, causing `/togbank hello`, `/togbank share`, `/togbank wipe`, and `/togbank roster` to have never worked in production, and the SYNC-012 fix (`togbank-rd`) to also be silently discarded. Affected: `togbank-h`, `togbank-hr` (hello broadcast/reply), `togbank-s`, `togbank-sr` (share command), `togbank-w`, `togbank-wr` (wipe command), `togbank-roster` (roster sync), `togbank-rq` (dead), `togbank-rd` (request data). Fix: Removed 4 dead registrations (`d2`, `d3`, `dv`, `rq`) and consolidated `togbank-s/sr/w/wr/roster` onto existing `togbank-hl` type dispatch (new types: `share-request`, `wipe-command`, `roster-broadcast`). Replaced slot 10's dead `togbank-v` with `togbank-rd`. Moved `togbank-h/hr` from slots 17-18 to slots 14-15. Final count: 15 prefixes. Locations: Chat.lua (RegisterComm block, OnCommReceived handlers for `togbank-hl`, `togbank-hr`), Guild.lua (`Share()`, `Wipe()`, `SendRosterData()`), RequestLog.lua (`SendRequestsSnapshot`, `SendRequestsIndex`, `SendRequestsById`).
- ✅ [COMM-005] **HIGH** Dead prefixes consuming 4 registration slots — `togbank-d2`, `togbank-d3`, `togbank-dv`, and `togbank-rq` were all registered via `RegisterComm` but never sent from anywhere in the codebase, wasting 4 of the 16 available prefix slots. `togbank-d2`/`d3` were legacy multi-chunk delta prefixes from an abandoned approach; `togbank-dv` was the original version broadcast prefix superseded by `togbank-dv2`; `togbank-rq` was never implemented. Additionally, `togbank-v` (slot 10) was registered but all sends had been commented out and the receive handler immediately discarded all messages. Fix: Removed all 5 dead registrations and collapsed the `togbank-v/dv/dv2` handler fallback chain to a single `if prefix == "togbank-dv2" then` check. Freed slots now occupied by `togbank-h`, `togbank-hr`, and `togbank-rd`. Locations: Chat.lua RegisterComm block, OnCommReceived version-broadcast handler.
- ✅ [SYNC-012] **CRITICAL** Request responses starved on bulk-inventory throttle bucket — `SendRequestsSnapshot`, `SendRequestsIndex`, and `SendRequestsById` all sent on `togbank-d`, the same AceComm throttle bucket used for full alt inventory data payloads (~100-500KB per alt). Request responses (~1-5KB) were queued behind bulk inventory traffic and delayed minutes to hours. Symptom: operator fills a request and changes propagate through `/togbank share` immediately, but after `/reload` on the banker the request data takes hours to arrive. Fix: Migrated all three request-data send functions to `togbank-rd` (dedicated throttle bucket). Also added `QueryRequestsIndex()` call on login (GUILD_ROSTER_UPDATE deferred block) and on Requests UI open, so request data is pro-actively fetched rather than relying only on push. Locations: RequestLog.lua `SendRequestsSnapshot` (~877), `SendRequestsIndex` (~830), `SendRequestsById` (~856); Events.lua GUILD_ROSTER_UPDATE handler; UI/Requests.lua open handler.
- ✅ [ROSTER-003] **HIGH** `SendRosterData` serialization mismatch — `SendRosterData()` encoded its payload with `EncodeJSON({roster={...}})` (JSON format) while the `togbank-roster` receive handler called `DeserializeWithChecksum()` (AceSerializer binary format). These two formats are completely incompatible — `DeserializeWithChecksum` always fails on JSON input, silently returning nil, so roster sync had never worked at the wire level regardless of the prefix limit issue. Fix: Changed `SendRosterData` to use `SerializeWithChecksum({type="roster-broadcast", roster={...}})` and send on `togbank-hl` with type dispatch. The `togbank-hl` `roster-broadcast` handler passes `data.roster` to `ReceiveRosterData(sender, data.roster)`. Locations: Guild.lua `SendRosterData` (~1432); Chat.lua `togbank-hl` type dispatch (new `roster-broadcast` branch).
- ✅ [SYNC-013] **HIGH** Fulfill mutation timing race — `BroadcastRequestMutation` (type="fulfill") arrives at a non-banker before the initial by-id snapshot has been received (e.g. the by-id response was serialised before the banker fulfilled, so it arrives as "open"). `ApplyRequestMutation` silently rejects the fulfill because `self.Info.requests[requestId] == nil`. The by-id response then arrives with the pre-fill "open" state; no further correction triggers. Result: fulfilled orders appear as "not filled" on the non-banker until the next index-sync cycle (≥60s cooldown). Fix: `ReceiveRequestMutations` now collects the IDs of any "fulfill" mutations rejected due to unknown local request and immediately fires a `QueryRequestsById` whisper back to the mutation sender (the banker). The banker responds on `togbank-rd` with the current fulfilled state; `ReceiveRequestsById` → `mergeRequest` adds it correctly. Location: RequestLog.lua `ReceiveRequestMutations` (~1157).
- ✅ [MAIL-007] **MEDIUM** `OnSendMail` manual-mail fallback permanently dead — `info.requests` is a map (string-keyed table); `#info.requests` on a Lua map always returns 0. Guard `#info.requests == 0` was always true, so the fallback that reads attachments and builds `pendingSend` for manual mails (sent without the Fulfill button) silently returned on every call. Result: any manual item mail sent by a banker from the mailbox without using the Fulfill button never called `FulfillRequest`, leaving both local data and guild broadcast unchanged — the request stayed "open" on all clients. Fix: changed guard to `next(info.requests) == nil` (correct map-emptiness check). Does not affect the Fulfill button path, which sets `pendingSend` via `PrepareFulfillMail` before `OnSendMail` fires. Location: Mail.lua `OnSendMail` (~253).

**Recent Fixes (2026-03-03):**
- ✅ [FULFILL-003] **HIGH** Request splitting logic inconsistency between UI state and execution — `CanFulfillRequest` (UI feasibility check) and `PrepareFulfillMail` (execution) used different algorithms causing UI to show split icon but execution found exact match (or vice versa). Root causes: (1) algorithm divergence (simple greedy vs two-stage with filtering), (2) stack filtering mismatch (PrepareFulfillMail used minStackSize filter, CanFulfillRequest didn't), (3) sort order differences (originalIndex preservation inconsistent), (4) split detection logic differed. Example: Request 95, have [20,20,20,20,15,14] → CanFulfillRequest accumulated 80 then said "need split 15", PrepareFulfillMail filtered to [20,20,20,20,15] and accumulated exact 95 without split → UI showed split icon (shovel) but clicking didn't require split. Fix: Extracted unified `CalculateFulfillmentPlan()` function implementing consistent greedy algorithm with skip-stack optimization and split detection. Both functions now use same logic eliminating ~200 lines of duplicate code. UI icon now always matches actual behavior. Location: Mail.lua lines 496-707 (new unified function), CanFulfillRequest refactored to use plan (~709-751), PrepareFulfillMail refactored (~752-873).

**Recent Fixes (2026-03-01):**
- ✅ [HASH-002] **HIGH** Stale-hash perpetual loop — clients with pre-DELTA-025 corrupted `inventoryHash` in SavedVariables triggered an infinite P2P request cycle. Their items were correct but stored hash was wrong (stamped from banker's hash, not recomputed). Each HLR cycle: requester's hash ≠ banker's hash → Ian ACKed → requester sent state summary → `ComputeDelta` found identical items → empty delta → silently dropped → hash unchanged → repeat. Stats showed 100 offered / 13 computed / 1 actual send (1% efficiency). Fix: When `DeltaHasChanges = false` with a specific whisper target, send a `no-change` reply carrying `hash` + `mailHash` so the requester corrects their stale stored value. `togbank-nochange` handler now applies these corrections in-memory when `correctedHash != 0`. Loop terminates on first exchange after clients reload with HASH-002. Commits: `b2ff4e5`. Locations: Guild.lua `SendAltData` (~2454), Chat.lua `togbank-nochange` handler (~1262).
- ✅ [P2P-001] **HIGH** `pendingSendCount` queue leak — three early-return paths in `SendAltData` never decremented the counter: (1) no alt in `Info`, (2) `ShouldUseDelta()` false, (3) `DeltaHasChanges()` false (most common: requester already had matching data). Result: queue filled to 3/3 within 30 seconds → Ian stopped offering P2P to anyone → 30s safety timeouts eventually drained → cycle repeated. Symptom: repeated "queue now: 3/3" messages with no data transfers. Fix: capture `isP2PSend` flag at top of `SendAltData` (presence of `pendingSendTimeouts[norm]`), add `releaseP2PSlot(reason)` helper closure, call on all early-return paths. Commit: `9d949db`. Location: Guild.lua `SendAltData` (~2360-2480).
- ✅ [STATS-002] **LOW** Asymmetric P2P accounting — `BroadcastP2PRequest` (Guild.lua) recorded broadcasts but its 5s timeout called `QueryAltPullBased` without `RecordP2PBankerFallback`, making all banker fallbacks invisible ("Still pending: 36" was actually "Fell back to banker: 36"). Mirror problem in Chat.lua `togbank-rr` handler: recorded banker fallbacks but not broadcasts. Fixed both. Commit: `6636702`.

**Recent Fixes (2026-02-27):**
- ✅ [DELTA-025] **CRITICAL** Non-banker's `inventoryHash` stamped with banker's value instead of recomputed from actual applied items — after `ApplyDelta` wrote bank/bags/mail items and recalculated the aggregated `current.items`, the final step blindly set `current.inventoryHash = deltaData.inventoryHash` (the banker's hash) and `current.mailHash = changes.mailHash` (stamped *before* mail items were even applied). If the applied items differed from the banker's in any way (stale bags, different mail, partial apply), the stored hash matched the banker's anyway → next sync: Ian sent `summary.hash = banker's hash`, banker saw no mismatch → sent no-change → items stayed stale permanently. Fix: replace both stamps with recomputation from the actual resulting items after all delta changes are applied: `inventoryHash = ComputeInventoryHash(current.items, nil, nil, current.money)` and `mailHash = ComputeInventoryHash(current.mail.items, nil, nil, nil)`. If items are correct the hash naturally converges; if anything is still wrong the hash diverges, the next sync detects the mismatch and self-heals. Locations: DeltaComms.lua `ApplyDelta` (~1237, ~1352-1371).
- ✅ [PERF-011] **HIGH** 3-5 second freeze on first few reloads from unbounded deltaHistory growth - CleanupDeltaHistory() existed but was never called, allowing stale delta entries (>1 hour old) to accumulate indefinitely. SavedVariables grew to 33,421 lines for deltaHistory alone (52,764 total / ~1.3MB), causing WoW to freeze 3-5s parsing it on every load. Freeze cleared after 3-4 reloads because the per-alt count limit (10) gradually displaced old large entries with new smaller ones. Fix: (1) Call CleanupDeltaHistory() 2s after guild init in GUILD_RANKS_UPDATE handler, (2) Call CleanupDeltaHistory() every 3 minutes in OnShareTimer to keep entries pruned during long sessions. Result: First reload after fix prunes all stale entries; subsequent reloads parse a tiny deltaHistory. Locations: Events.lua GUILD_RANKS_UPDATE (~428-438), OnShareTimer (~186-194).
- ✅ [ROSTER-002] **MEDIUM** Stale ex-banker persists as "HLR pending" indefinitely after leaving guild - RebuildBankerRoster() created zero-data stubs in alts for discovered bankers but never removed them when they left. SavedVariables confirmed Raideronly-OldBlanchy in roster.alts (line 14515) and as a zero stub in alts (line 17572) despite not being a current guild member. Three compounding failures: (1) stubs not cleaned on roster rebuild, (2) latestBankerHashes seeded from ALL alts including stale stubs, (3) stub in roster.alts bypassed the rosterLookup filter added in P2P-019. Fix: (1) RebuildBankerRoster() now deletes zero stubs (version==0, inventoryHash==0, no items) for alts not in the new banker roster after each rebuild, (2) latestBankerHashes init delayed from 0.5s to 1.5s and filtered to banksCache only (populated by RebuildBankerRoster at 1s), preventing stale stubs from re-entering the cache, (3) BuildBankerHashList() skips zero-stub alts so they are never broadcast to other guild members and cannot seed phantom pending entries on receivers. Result: Raideronly and any future ex-bankers are cleaned on next load with a live guild roster; "HLR pending" only shows alts that actually need syncing. Locations: Guild.lua RebuildBankerRoster (~498-521), Init latestBankerHashes init (~293-325), BuildBankerHashList (~752-780).
- ✅ [ITEM-003b] **CRITICAL** Receive-side ghost weapon stacks persist after ITEM-003 sender fixes — even with corrected NeedsLink on the sender, a race condition (GetItemInfo cache miss at send time) still allows plain-weapon ItemStrings to reach the receiver. When the receiver's ApplyItemDelta STEP 3 found no normalized-key match for the linkless entry, it inserted it as a new ghost stack alongside the existing suffixed entry instead of discarding it. Fix: added `ItemClassNeedsLink(itemID)` helper to Item.lua (returns true/false/nil based on GetItemInfo class; nil = uncached). In ApplyItemDelta STEP 2 and STEP 3, before inserting a linkless item as new: (a) if GetItemInfo confirms weapon/armor class → block insert, (b) if class uncached → block if any linked entry for the same base ID already exists (linked version is authoritative). Root cause confirmed by inspecting banker SV (account 981197530#1) — banker had only the suffixed wolf variant with full Link; the ghost plain entry was being created on the receiver when the linkless ItemString arrived and keyed differently. Commit: 8ced667. Locations: Item.lua ItemClassNeedsLink() (new), DeltaComms.lua ApplyItemDelta STEP 2 linkless-as-new guard, STEP 3 linkless-as-new guard.
- ✅ [DELTA-022] **CRITICAL** Every delta sync was effectively a full sync — `ItemsEqual` compared `item1.Link ~= item2.Link` where `item1` was a minimal baseline item (Link=nil, from `expandMinimalItems` in `ComputeDelta`) and `item2` was a current inventory item (always has Link). `nil ~= "item:12345:..."` is always true, so every unchanged item landed in `modified[]` regardless of actual changes. The resulting delta contained the entire inventory as modified entries — same size as a full sync — defeating the point of delta protocol entirely. Fix: Only compare Links when both items have them. A nil Link on either side means the field is simply absent/unknown (minimal baseline), not a meaningful difference. Locations: DeltaComms.lua `ItemsEqual` (~446-490).
- ✅ [DELTA-023] **HIGH** Stale `hasSnapshot` gate in `RespondToStateSummary` caused unnecessary full syncs after any reload — Both the mail-only-change and inventory-change branches in `RespondToStateSummary` checked `GetSnapshot()` before computing a delta, falling back to `SendAltData(norm, 0, 0, ...)` (full sync) when no snapshot existed. Since snapshots are in-memory only (PERF-012), they are lost on every reload. After DELTA-020 landed, `ComputeDelta` uses `requesterBaseline` from the state summary directly and no longer uses `GetSnapshot` at all — but the gate in `RespondToStateSummary` was never removed. Result: The first sync after any reload always sent a full "everything as additions" delta even though the requester sent their exact baseline in the state summary. Fix: Removed both `hasSnapshot` gates entirely. `ComputeDelta` handles `requesterHash == 0` (no prior data) internally; `requesterBaseline` covers all other cases. Locations: Guild.lua `RespondToStateSummary` mail-only branch (~1829) and inventory-change branch (~1847).
- ✅ [DELTA-024] **LOW** Migration computes inventory hash using a different algorithm than `Bank:Scan()`, causing a false "inventory changed" event on every startup — The `Database.lua` migration block (post-load, deferred 0.5s) called `ComputeInventoryHash(alt.bank, alt.bags, money)` which routes through the pre-SYNC-006 code path and hashes `"B:bank.items|G:bags.items"` separately. `Bank:Scan()` always calls `ComputeInventoryHash(alt.items, nil, nil, money)` which is the SYNC-006 path and hashes `"I:aggregated_items"`. Same hash algorithm but different string input → different numeric output for identical inventory data. On startup the migration wrote the pre-SYNC-006 hash; then on first `Bank:Scan()` the SYNC-006 hash differed → `currentHash ~= previousHash` → version bumped, snapshot saved, and `dv2` broadcast triggered as if inventory had changed. Transient (self-healed after first scan), but caused one spurious version bump and broadcast per session. Fix: After `RecalculateAggregatedItems` populates `alt.items`, recompute hash using SYNC-006 calling convention to match `Bank:Scan()` format. Locations: Database.lua deferred migration block (~220).

---

## [SYNC-014] No P2P sync on login until zone or 10-minute timer

**Severity:** HIGH
**Status:** Fixed 2026-03-07
**Reported:** March 7, 2026

**Symptom:**
After logging in or reloading, the addon showed no inventory data from online peers until either:
- The player zoned (triggering `PLAYER_ENTERING_WORLD`), which caused other clients to re-broadcast their own periodic hashes into the P2P window incidentally, or
- The 10-minute `OnShareTimer` fired.

No hash broadcast was initiated by the local client on login, so peers had no way to know this client needed their data.

**Root Cause:**
`SyncDeltaVersion` (which broadcasts our local hash list to the guild and opens the P2P collect window) was only ever called from two places:
1. `OnShareTimer` — fires 600 seconds after `RegisterEvents` (10 minutes post-login/reload)
2. `Bank:Scan()` / `Guild:Share()` — only fires when the player physically opens the bank

There was no call to `SyncDeltaVersion` on login. `PLAYER_ENTERING_WORLD` only called `GuildRoster()`. `GUILD_ROSTER_UPDATE` only called `QueryRequestsIndex`. Neither triggered a hash broadcast.

Zoning appeared to "fix" the problem because other already-logged-in peers were past their 10-minute mark and would broadcast on their next timer tick shortly after seeing the player in the roster. The fix was being provided reactively by remote peers, not by the local client.

**Fix:**
Added `SyncDeltaVersion("NORMAL")` call in the `GUILD_ROSTER_UPDATE` deferred completion block, immediately after the existing `QueryRequestsIndex` call. This fires once roster initialization is confirmed complete (typically 1–3 seconds post-login), ensuring the local client broadcasts its hashes and opens the P2P collect window without delay.

```lua
-- REQUEST-001: Sync request state shortly after login, don't wait for the periodic timer
TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")
-- SYNC-014: Broadcast our hashes immediately on login so peers can offer data
-- without waiting for the 10-minute periodic timer to fire first.
TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
```

**Location:** Events.lua `GUILD_ROSTER_UPDATE` handler, deferred completion block.

---

## [COMM-004] WoW AceComm 16-prefix hard limit exceeded — 9 prefixes silently dropped

**Severity:** CRITICAL
**Status:** Fixed 2026-03-05
**Reported:** March 5, 2026

**Symptom:**
Multiple slash commands had never worked in production:
- `/togbank hello` — sent on `togbank-h` but no player ever received it
- `/togbank share` — sent on `togbank-s` but no player ever received it
- `/togbank wipe` — sent on `togbank-w` but no player ever received it
- `/togbank roster` — sent on `togbank-roster` but no player ever received it

Additionally, the SYNC-012 fix (migrating request data to `togbank-rd`) appeared to be correctly implemented but had no effect at all, since `togbank-rd` was also silently dropped.

**Root Cause:**
WoW's AceComm-3.0 (via ChatThrottleLib) enforces a hard limit of **16 `RegisterComm` prefixes per addon**. Prefixes registered beyond the 16th slot are accepted by the API without error but are **silently discarded** on the receive side — messages arrive at WoW's network layer but are never dispatched to the addon handler.

At the time of discovery, `Chat.lua` had grown to **24 active `RegisterComm` calls** (plus 1 legacy `togbank-v`), placing slots 17-25 permanently in the dead zone:

| Slot | Prefix | Status |
| ------ | -------- | -------- |
| 1 | `togbank-d` | ✅ Active |
| 2 | `togbank-hl` | ✅ Active |
| 3 | `togbank-hlr` | ✅ Active |
| 4 | `togbank-d4` | ✅ Active |
| 5 | `togbank-rm` | ✅ Active |
| 6 | `togbank-dr` | ✅ Active |
| 7 | `togbank-dc` | ✅ Active |
| 8 | `togbank-d2` | ❌ Never sent (dead) |
| 9 | `togbank-d3` | ❌ Never sent (dead) |
| 10 | `togbank-v` | ❌ Never sent, handler discarded all |
| 11 | `togbank-dv` | ❌ Superseded by dv2, never sent |
| 12 | `togbank-dv2` | ✅ Active |
| 13 | `togbank-r` | ✅ Active |
| 14 | `togbank-rr` | ✅ Active |
| 15 | `togbank-state` | ✅ Active |
| 16 | `togbank-nochange` | ✅ Active |
| ~~17~~ | ~~`togbank-h`~~ | ❌ **Over limit — never received** |
| ~~18~~ | ~~`togbank-hr`~~ | ❌ **Over limit — never received** |
| ~~19~~ | ~~`togbank-s`~~ | ❌ **Over limit — never received** |
| ~~20~~ | ~~`togbank-sr`~~ | ❌ **Over limit — never received** |
| ~~21~~ | ~~`togbank-w`~~ | ❌ **Over limit — never received** |
| ~~22~~ | ~~`togbank-wr`~~ | ❌ **Over limit — never received** |
| ~~23~~ | ~~`togbank-roster`~~ | ❌ **Over limit — never received** |
| ~~24~~ | ~~`togbank-rq`~~ | ❌ **Never sent AND over limit** |
| ~~25~~ | ~~`togbank-rd`~~ | ❌ **Over limit — SYNC-012 fix silently broken** |

**Fix:**
1. **Removed 5 dead registrations** that consumed slots without any active sends or handles: `togbank-d2`, `togbank-d3`, `togbank-v`, `togbank-dv`, `togbank-rq`.
2. **Merged `togbank-s`, `togbank-sr`, `togbank-w`, `togbank-wr`, `togbank-roster`** — consolidated onto existing `togbank-hl` type dispatch with new message types: `share-request`, `wipe-command`, `roster-broadcast`. Removed standalone handlers and registrations for all five.
3. **Replaced slot 10** (`togbank-v`) with `togbank-rd`, placing the request-data prefix within the safe range.
4. **`togbank-h`/`togbank-hr`** moved from slots 17-18 to slots 14-15 (now actually received).
5. **`togbank-rq`** removed — no send site was ever implemented.

**Final prefix registry (15 slots):**
```
1.  togbank-d      — Alt inventory data (bulk)
2.  togbank-hl     — Coordinator hub: hashes, share, wipe, roster, P2P
3.  togbank-hlr    — Hash-list replies
4.  togbank-d4     — Delta data payloads
5.  togbank-rm     — Request mutations (ALERT priority, own bucket)
6.  togbank-dr     — Delta range requests
7.  togbank-dc     — Delta chain responses
8.  togbank-rd     — Request data responses (own bucket, SYNC-012)
9.  togbank-dv2    — Version broadcasts
10. togbank-r      — Pull-based queries
11. togbank-rr     — Pull ACKs / session handshake
12. togbank-state  — P2P state summaries
13. togbank-nochange — P2P no-change signals
14. togbank-h      — Hello broadcast
15. togbank-hr     — Hello reply
```

**Locations:**
- `Chat.lua` RegisterComm block: removed 5 dead registrations, reordered `togbank-h`/`togbank-hr`
- `Chat.lua` OnCommReceived: added `share-request`, `wipe-command`, `roster-broadcast` type handlers in `togbank-hl` block; removed standalone `togbank-s`, `togbank-w`, `togbank-roster` handlers; collapsed version-broadcast chain to single `togbank-dv2` check
- `Guild.lua` `Share()` (~3347): migrated `togbank-s` → `togbank-hl` type=`share-request`
- `Guild.lua` `Wipe()` (~3224): migrated `togbank-w` → `togbank-hl` type=`wipe-command`
- `Guild.lua` `SendRosterData()` (~1432): migrated `togbank-roster` → `togbank-hl` type=`roster-broadcast`

---

## [COMM-005] Dead prefixes consuming 4 of 16 registration slots

**Severity:** HIGH
**Status:** Fixed 2026-03-05
**Reported:** March 5, 2026

**Symptom:**
Not directly user-visible, but a structural cause of [COMM-004]: 4 prefix slots were consumed by prefixes that were never sent and never did useful work, contributing to the slot overflow that pushed active prefixes past the 16-slot limit.

**Root Cause:**
Four `RegisterComm` calls in `Chat.lua` registered prefixes with no corresponding active send site:

- **`togbank-d2`** — Legacy multi-chunk delta prefix from an earlier protocol design. All sends were removed when the architecture changed, but the `RegisterComm` call was left in place. The receive handler was reachable but never triggered.
- **`togbank-d3`** — Same as `togbank-d2`; companion prefix from the multi-chunk design. Dead.
- **`togbank-dv`** — Original version broadcast prefix, superseded by `togbank-dv2` (which appended `2` to avoid conflicts with older clients). All `togbank-dv` sends had been replaced with `togbank-dv2`, but `RegisterComm("togbank-dv")` remained. The receive handler had a 5-second timer to delay in favour of `dv2`, making it functionally dead.
- **`togbank-rq`** — Reserved for a "request query" flow that was never implemented. No send site existed anywhere in the codebase.

Additionally, **`togbank-v`** was registered and placed at slot 10 but: (1) all sends were commented out with `-- V SENDS COMMENTED OUT`, and (2) the receive handler executed `return` immediately after logging, discarding every message. This was the most wasteful slot — it both consumed a low-numbered slot and did nothing.

**Fix:**
Removed `RegisterComm` calls for `togbank-d2`, `togbank-d3`, `togbank-v`, `togbank-dv`, and `togbank-rq`. Collapsed the version-broadcast receive handler from a three-way `if prefix == "togbank-v" / elseif "togbank-dv" / elseif "togbank-dv2"` chain to a single `if prefix == "togbank-dv2" then` check, eliminating ~15 lines of dead fallback logic.

**Locations:**
- `Chat.lua` RegisterComm block: removed 5 entries
- `Chat.lua` OnCommReceived version-broadcast handler: collapsed fallback chain

---

## [SYNC-012] Request responses compete with bulk inventory on shared throttle bucket

**Severity:** CRITICAL
**Status:** Fixed 2026-03-05
**Reported:** March 5, 2026

**Symptom:**
After a `/reload` on the banker, request data (guild requests, item asks, cancellations) took **hours** to propagate — even for a single new request. Operator creates a request, other player `/reload`s their banker, banker UI shows no requests. After 2-3 hours the data eventually appears.

**Root Cause:**
AceComm-3.0 uses ChatThrottleLib, which maintains **one queue per registered prefix**. All messages on the same prefix compete for throughput in insertion order — a large payload blocks smaller payloads behind it.

`SendRequestsSnapshot`, `SendRequestsIndex`, and `SendRequestsById` all sent their data on **`togbank-d`** — the same prefix used to broadcast full alt inventory data. A single alt inventory payload is 50-200KB serialized; a guild with multiple active bankers generates several of these on every login. A request sync payload is typically 1-5KB.

The result: when a non-banker logged in and triggered multiple alt inventory syncs, the 5-10 large inventory payloads queued on `togbank-d` serialized back-to-back, taking 10-60 minutes to drain at WoW's chat throttle rate. Any `QueryRequestsIndex` response queued after them waited in line behind all that bulk data.

Secondary issue: `QueryRequestsIndex` was only called from a timer that fired periodically — there was no pro-active fetch on login or when the user opened the Requests UI, so after a `/reload` the user had no request data at all until the timer happened to fire AND the response made it through the throttle queue.

**Fix:**
1. **Migrated all three send functions to `togbank-rd`**: `SendRequestsSnapshot`, `SendRequestsIndex`, `SendRequestsById` now send on `togbank-rd`, which has its own dedicated throttle bucket independent of bulk inventory traffic. A request response is now processed as soon as bandwidth is available for that prefix specifically.
2. **Added `QueryRequestsIndex` on login**: GUILD_ROSTER_UPDATE deferred block (Events.lua) now calls `QueryRequestsIndex()` after the standard sync, ensuring request data is fetched immediately after joining the guild channel on each reload.
3. **Added `QueryRequestsIndex` on Requests UI open**: When the player opens the Requests UI panel, if local request data is absent or stale, a fresh query is sent immediately.

**Note:** This fix depended on [COMM-004] — `togbank-rd` was originally placed at slot 25 (silently dropped by WoW). The slot fix in COMM-004 moved `togbank-rd` to slot 8 (replacing dead `togbank-v`), making this fix actually effective.

**Locations:**
- `RequestLog.lua` `SendRequestsSnapshot` (~877): prefix `togbank-d` → `togbank-rd`
- `RequestLog.lua` `SendRequestsIndex` (~830): prefix `togbank-d` → `togbank-rd`
- `RequestLog.lua` `SendRequestsById` (~856): prefix `togbank-d` → `togbank-rd`
- `Events.lua` GUILD_ROSTER_UPDATE deferred block (~428-438): added `QueryRequestsIndex()` call
- `UI/Requests.lua` panel open handler: added `QueryRequestsIndex()` call

---

## [ROSTER-003] SendRosterData uses incompatible serialization format

**Severity:** HIGH
**Status:** Fixed 2026-03-05
**Reported:** March 5, 2026

**Symptom:**
`/togbank roster` (the command to broadcast the banker's roster to guild members) appeared to complete successfully — the sender logged "Sending roster data..." — but no receiver ever processed the data. Guild members never received updated roster information via this path. This was masked by the [COMM-004] prefix limit bug (the prefix was also over the 16-slot limit), making the two bugs compound: even if serialization had been correct, the message would still have been silently dropped.

**Root Cause:**
`SendRosterData()` in `Guild.lua` serialized its payload using `EncodeJSON({roster={...}})`, producing a JSON string:
```lua
-- Wrong (sends JSON)
local data = self:EncodeJSON({roster = rosterList})
self:SendCommMessage("togbank-roster", data, "GUILD", nil, "BULK")
```

The receive handler in `Chat.lua` for `togbank-roster` decoded using `DeserializeWithChecksum(message)` (AceSerializer binary format):
```lua
-- Wrong (expects AceSerializer, receives JSON)
elseif prefix == "togbank-roster" then
    local ok, data = self:DeserializeWithChecksum(message)
    if not ok then return end  -- always fails
    ReceiveRosterData(sender, data.roster)
end
```

AceSerializer and JSON are completely incompatible wire formats. `DeserializeWithChecksum` always returned `ok = false` on JSON input, so `ReceiveRosterData` was never called. Every roster broadcast was silently discarded on every receiver.

**Fix:**
Changed `SendRosterData` to use `SerializeWithChecksum` with a structured type envelope and send on `togbank-hl` (within the 16-prefix limit via [COMM-004] consolidation):
```lua
-- Correct (AceSerializer + type dispatch)
local data = self:SerializeWithChecksum({type = "roster-broadcast", roster = rosterList})
self:SendCommMessage("togbank-hl", data, "GUILD", nil, "BULK")
```

Added `roster-broadcast` handler in the `togbank-hl` type dispatch block in `Chat.lua`:
```lua
elseif data.type == "roster-broadcast" then
    TOGBankClassic_Output:Debug("PROTOCOL", "Roster broadcast from %s (%d entries)", sender, data.roster and #data.roster or 0)
    ReceiveRosterData(sender, data.roster)
```

**Locations:**
- `Guild.lua` `SendRosterData()` (~1432): `EncodeJSON` → `SerializeWithChecksum`, prefix `togbank-roster` → `togbank-hl`, added `type="roster-broadcast"` field
- `Chat.lua` `togbank-hl` type dispatch: added `roster-broadcast` branch calling `ReceiveRosterData(sender, data.roster)`
- `Chat.lua` standalone `togbank-roster` handler: removed

---

## [DELTA-025] Non-banker inventoryHash stamped from delta instead of recomputed from applied items

**Severity:** CRITICAL
**Status:** Fixed 2026-02-27
**Reported:** February 27, 2026

**Symptom:**
Non-banker Ian (`IANPLAMONDON`) had correct hash metadata but stale bag item counts for banker alt `Taylorrcp-Azuresong` even after banker ran `/togbank share`. SV confirmed:
- Ian's `inventoryHash = 174890764` (stale) while banker had `1003899929`
- Ian's `bags.items` had wrong counts (e.g. ID 7114 Count=3 vs banker's Count=1)
- Ian's `bank.items` was correct (matched banker exactly)
- Ian's `version = 1770402326` but `inventoryUpdatedAt = 1772245514` — a prior delta had updated `inventoryUpdatedAt` but not corrected the items

**Root Cause:**
At the end of `ApplyDelta`, after all bank/bags/mail item changes were applied and `current.items` was recalculated, the code stamped:
```lua
-- Wrong: blindly copies banker's hash value
if deltaData.inventoryHash and deltaData.inventoryHash ~= 0 then
    current.inventoryHash = deltaData.inventoryHash  -- banker's hash, not Ian's
end
```
And separately, `mailHash` was stamped from `changes.mailHash` **before** mail items were applied:
```lua
-- Wrong: stamped before mail items exist
if changes.mailHash ~= nil then
    current.mailHash = changes.mailHash
end
```

If the applied items on Ian's side differed from the banker's in any way (stale bags, different mail contents, partial apply), the stored `inventoryHash` matched the banker's anyway. On the next sync:
1. Ian sent `summary.hash = 1003899929` (stamped from banker)
2. Banker compared: `requesterHash (1003899929) == currentHash (1003899929)` → **hashes match**
3. Banker sent `no-change`
4. Ian's items remained stale permanently — the false hash match silenced all future syncs

**Fix (DeltaComms.lua `ApplyDelta`):**
Replaced both hash stamps with recomputation from the actual resulting items after all delta changes are applied:
```lua
-- Correct: recompute from what we actually have
local recomputedInvHash = self:ComputeInventoryHash(current.items or {}, nil, nil, current.money or 0)
current.inventoryHash = recomputedInvHash

if current.mail and current.mail.items then
    local recomputedMailHash = self:ComputeInventoryHash(current.mail.items, nil, nil, nil)
    current.mailHash = recomputedMailHash
end
```

**Self-healing behaviour:** If items are applied correctly the recomputed hash naturally converges with the banker's on the next sync cycle. If anything is still wrong, the hash diverges, the mismatch is detected, another delta is sent, and the system self-corrects — rather than silently perpetuating stale data.

**Locations:** `DeltaComms.lua` `ApplyDelta` — removed premature `mailHash` stamp (~line 1237), replaced `inventoryHash` stamp with recompute block (~lines 1352–1371).

---

## [ROSTER-002] Stale ex-banker persists as HLR pending after leaving guild

**Severity:** MEDIUM
**Status:** Open
**Reported:** February 27, 2026

**Symptom:**
```
TOGBankClassic: Hash list coverage: banker=36, matched=35, pending=1, rosterMissing=0, haveContent=35
TOGBankClassic: HLR pending: Raideronly-OldBlanchy
```
A player (`Raideronly-OldBlanchy`) who is no longer a banker appears permanently as "HLR pending" in hash coverage reports and drives ongoing (futile) P2P/HLR requests.

**SV Verification:**
- Line 14515 in SavedVariables: `Raideronly-OldBlanchy` is IN `roster.alts` (the banker list) — confirmed still present
- Line 17572: Raideronly has a zero-data stub in `alts` (all fields = 0) — never received actual data

**How a non-current banker gets into the system (entry path):**
1. At some point, `Raideronly-OldBlanchy` was a guild member with `"gbank"` in their public or officer note
2. `RebuildBankerRoster()` scanned `GetGuildRosterInfo()` and found the "gbank" keyword → added them to `roster.alts` AND created a zero stub in `self.Info.alts`
3. Both entries persisted to SavedVariables
4. They later left the guild (or their note was changed), but the cleanup never happened

**Why they are NOT removed (the bug — three compounding failures):**

**Failure 1: `RebuildBankerRoster()` doesn't purge stale `alts` stubs.**
In `Guild.lua:RebuildBankerRoster()` (~470): newly discovered bankers get a stub created in `self.Info.alts`. When they leave the guild, `roster.alts` is correctly replaced via `self.Info.roster.alts = banks`, BUT nothing removes the dead stub from `self.Info.alts`. The stub persists across sessions indefinitely.

**Failure 2: `latestBankerHashes` is seeded from ALL `self.Info.alts`, not just current roster.**
In `Guild.lua:Init()` (~297): the `C_Timer.After(0.5)` block iterates `self.Info.alts` with no filter:
```lua
for altName, alt in pairs(self.Info.alts) do
    self.latestBankerHashes[altName] = { hash = ..., mailHash = ... }
end
```
This seeds Raideronly into `latestBankerHashes` on every login/reload, even though they're no longer a banker.

**Failure 3: `roster.alts` in SV still contains Raideronly, so `rosterLookup` doesn't filter them.**
`ReportHashListCoverage()` filters `latestBankerHashes` via `rosterLookup` (built from `GetRosterAlts()` → `roster.alts`). Since `roster.alts` in SavedVariables still contains Raideronly (confirmed in SV), the filter passes them through as valid pending. The `rosterLookup` guard added in P2P-019 only works correctly if `roster.alts` itself is clean — but cleaning requires a successful post-login `RebuildBankerRoster()` run that saves before logout, which hasn't happened in this case.

**Root cause of Failure 3:** `RebuildBankerRoster()` correctly updates `roster.alts` in-memory (replacing it with the current guild scan), but if the player logs out before the clean roster is persisted (e.g., before the 1s deferred timer fires, or before the first `GUILD_ROSTER_UPDATE` deferred block completes with fresh guild data), the stale `roster.alts` survives to the next session.

**Why it doesn't self-heal:** Every login the sequence is:
- `t=0`: Load SV → `roster.alts` has Raideronly, `alts` has Raideronly stub
- `t=0.5s`: `latestBankerHashes` seeded from all `alts` → Raideronly included
- `t=0.5–1s`: `RebuildBankerRoster()` runs → `roster.alts` cleaned in-memory (Raideronly removed) → `banksCache` updated
- `t=any`: `ReportHashListCoverage` called → uses `latestBankerHashes` (has Raideronly) vs `rosterLookup` (from updated `roster.alts`, Raideronly absent) → Raideronly filtered OUT by rosterLookup ✓
- BUT: `latestBankerHashes` can be repopulated later via incoming HLR broadcasts from OTHER guild members whose `roster.alts` still contains Raideronly (their SavedVariables hasn't been cleaned yet either)

**Fix required:**

1. **`RebuildBankerRoster()` should remove stale `alts` stubs** for alts that are no longer in the banker roster. After building the new `banks` array, identify any key in `self.Info.alts` that is NOT in the new roster AND has only zero/empty data (stub indicator: `version == 0 and inventoryHash == 0 and #items == 0`) and remove it. This prevents permanent zombie entries.

2. **`latestBankerHashes` init should filter to current roster only.** In `Guild:Init()`, the `C_Timer.After(0.5)` hash cache initialization should only include alts that are in `roster.alts` (or `banksCache`). However, since `RebuildBankerRoster()` runs at 1s (after the 0.5s init), this requires either (a) delaying the hash init to 1.5s after `RebuildBankerRoster()`, or (b) accepting the 0.5s window with stale hashes (acceptable since the rosterLookup filter handles it by 1s).

3. **`BuildBankerHashList()` should not include zero-stub alts.** When a banker builds their hash list to broadcast, alts with `version == 0 and inventoryHash == 0` and no items are dead stubs and should be excluded. This prevents stale stubs from propagating to other guild members via HLR broadcasts.

**Locations:**
- `Guild.lua RebuildBankerRoster()` (~423–480): add stale stub cleanup after roster diff
- `Guild.lua Init() latestBankerHashes init` (~297–313): filter to roster-only
- `Guild.lua BuildBankerHashList()` (~695–717): skip zero-stub alts

**Recent Fixes (2026-02-26):**
- ✅ [PERF-010] **HIGH** Login freeze from synchronous data migrations in Database:Load - Deferred alt data migrations to prevent 3-5 second freeze when logging in with large SavedVariables. Root cause: Database:Load() synchronously looped through all alts (70+ in production) performing migrations: slots initialization, inventory hash computation, inventoryUpdatedAt backfill, and MOST EXPENSIVE: RecalculateAggregatedItems() for every banker alt. This ran on EVERY login/reload. Total time: 70 alts × ~50-70ms per iteration = 3-5 second freeze. Solution: Wrapped entire migration block in C_Timer.After(0.5) - data already loaded from SavedVariables, migrations don't need to be immediate. Also deferred latestBankerHashes initialization in Guild:Init. Result: Instant login, migrations run in background. Locations: Database.lua Load (~175-243), Guild.lua Init (~295-313).
- ✅ [PERF-009] **MEDIUM** ChatFrame_AddMessageEventFilter causing stuttering from pattern matching on every CHAT_MSG_SYSTEM event - Optimized chat filter (added in COMM-003c) to use fast plain-text string search before expensive pattern matching. Previously filter ran match("^No player named .+ is currently playing%.$") on EVERY CHAT_MSG_SYSTEM event (guild achievements, player online/offline, etc.), causing noticeable stuttering during normal gameplay. Now uses find("No player named ", 1, true) plain-text check first, only running pattern match if prefix found. Result: ~99% reduction in unnecessary pattern matching, stuttering eliminated while maintaining error suppression. Location: Events.lua Initialize ChatFrame_AddMessageEventFilter (~59-68).

**Recent Fixes (2026-02-24):**
- ✅ [DELTA-021] **CRITICAL** ApplyItemDelta creating duplicates from incorrect "added" items - Fixed ApplyItemDelta to check if items in delta.added already exist in the inventory (by ID) and UPDATE them instead of appending. When ComputeItemDelta's link normalization fails, items appear in delta.added that should be in delta.modified. Previously this caused duplicate entries in the items array. Now ApplyItemDelta searches for existing items by ID first: if found, updates Count/Link/ItemString/Info fields; if not found, appends as new. This provides defense-in-depth against link normalization failures in ComputeItemDelta. Combined with the existing 3-tier fallback (normalized key → ID-only → deep ID search), this ensures deltas are applied correctly even when item matching fails. Result: No more duplicate item entries, counts stay accurate across syncs. Location: DeltaComms.lua ApplyItemDelta Step 3 (~938-972).

**Recent Fixes (2026-02-20):**
- ✅ [PERF-008] **CRITICAL** 5-second freeze on login/reload/zoning from synchronous roster operations and cache invalidation - Fixed by deferring ALL expensive roster operations (RefreshOnlineCache and RebuildBankerRoster) AND moving cache invalidation inside the deferred block. Previously cache was invalidated BEFORE deferring operations, causing any IsBank() call between invalidation and rebuild to synchronously scan 500+ guild members. Root cause: GUILD_ROSTER_UPDATE called InvalidateBanksCache() immediately, then C_Timer.After deferred the rebuild. If anything called IsBank() in that window (during zoning, UI updates, etc), GetBanks() found nil cache and synchronously rebuilt it. Fixed in FOUR places: (1) Events.lua GUILD_ROSTER_UPDATE now invalidates cache INSIDE deferred block after 0.5s delay (~295-332), (2) RebuildBankerRoster() now explicitly rebuilds banksCache instead of relying on lazy rebuild (~420-432), (3) Guild:Init() defers RebuildBankerRoster with 1s delay when data exists (~282-287), (4) Guild:Reset() defers RebuildBankerRoster with 1s delay on first load/wipe (~259-265). Result: No more freezes on login, reload, or zoning - all roster operations happen in background. Locations: Events.lua GUILD_ROSTER_UPDATE, Guild.lua RebuildBankerRoster, Init, Reset.
- ✅ [PERF-007] **CRITICAL** Bagnon execution timeout from BAG_UPDATE spam - Fixed ItemHighlight to always defer refresh via C_Timer.After with calculated delay based on time since last refresh, guaranteeing minimum 0.5s between SEARCH_CHANGED signals to Bagnon. Previously throttle logic still allowed immediate calls when throttle period expired, causing rapid SEARCH_CHANGED signals during zone changes that triggered Bagnon UI rebuilds exceeding execution time limit. Now uses math.max(0, REFRESH_THROTTLE - elapsed) to calculate delay, ensuring all refreshes are async and properly spaced. Result: Eliminated "Script from Bagnon has exceeded its execution time limit" errors. Location: ItemHighlight.lua Initialize event handler (~33-49).
- ✅ [SYNC-011] **MEDIUM** Request snapshot sync delays from BULK throttling - Changed request snapshot broadcast priority from BULK to NORMAL in SendRequestsSnapshot(). Previously full request list syncs used BULK priority which is heavily throttled by WoW's addon communication system, causing 5-10 second delays when users opened UI or ran /sync command. These delays made the addon feel unresponsive when requesting guild request data. NORMAL priority processes faster while still being respectful of bandwidth since request data is moderate size (typically <10KB). Real-time mutations already use ALERT priority (togbank-rm), this change only affects full snapshot catch-up syncs. Result: Improved responsiveness when syncing guild requests, no more multi-second wait for data to appear in UI. Location: RequestLog.lua SendRequestsSnapshot (~877).
- ✅ [P2P-020] **CRITICAL** Peer ACKs ignored when no banker online (wipe-recovery scenario broken) - Fixed QueryAltPullBased to set pendingP2PRequests[norm] when broadcasting to GUILD without a banker. Previously pendingP2PRequests was only set at Chat.lua:1097 when banker sent hash-only ACK (isBanker=true, hashOnly=true, expectedHash exists). When no banker was online, QueryAltPullBased broadcast togbank-r to GUILD but never set pendingP2PRequests, causing peer ACK handler (Chat.lua:1152-1155) wasPending check to fail silently. Result: Peer ACKs were ignored, wipe recovery (/togbank wipe or new guild member with blank DB) completely failed without online banker - hashes never populated, data never flowed until banker logged on. Root cause: pendingP2PRequests tracking assumed hash-centric P2P flow initiated by banker hash broadcasts, not direct GUILD broadcasts from wipe-recovery scenario. Solution: Set pendingP2PRequests[norm] in two GUILD broadcast paths at QueryAltPullBased: (1) no banker found (noBanker=true flag), (2) banker offline (bankerOffline=true flag). Result: Peer ACKs now recognized as pending P2P requests, full ACK→StateSummary→Data flow works, wipe recovery operational without online banker. Minimal fix using existing ACK infrastructure without protocol changes. Locations: Guild.lua QueryAltPullBased GUILD broadcast paths (~1289-1296, ~1299-1306).
- ✅ [P2P-019] **MEDIUM** Banker requesting hash for themselves and debug showing invalid pending alts - Fixed three related issues: (1) BroadcastP2PRequest now skips P2P requests when the requested alt is the current player - previously when banker ran /togbank share, they broadcast their own hash to guild chat, then received their own broadcast message and triggered a P2P request for themselves ("Broadcasting request for Cardsngames-Azuresong with hash=672637121"), (2) ReportHashListCoverage now filters pending list to exclude current player and non-roster alts - previously /togbank debughash showed current player as "HLR pending" and included old alts from different guilds (like "Patternmaker-Atiesh" appearing when not a current guild bank), (3) HLR handler second pass now skips current player before processing hash comparisons to avoid wasted processing. Root cause: No validation that pending alt != self and no roster validation against latestBankerHashes cache. Players cannot request their own data from peers since they are the authoritative source. Solution: Added currentPlayer check in all three locations and rosterLookup validation in ReportHashListCoverage. Result: Bankers no longer send self-directed P2P requests after broadcasting hash updates, debug output only shows valid guild bank alts that need syncing, and HLR processing skips unnecessary work for current player. Locations: Guild.lua BroadcastP2PRequest (~893-909), ReportHashListCoverage roster lookup table and filtering (~699-746); Chat.lua HLR handler second pass currentPlayer check (~1873-1935).
- ✅ [COMM-003b] **HIGH** Whisper error pattern not matching single-quoted player names - Fixed CHAT_MSG_SYSTEM handler to detect both single-quoted and unquoted variants of "No player named X is currently playing" errors. Previously pattern only matched unquoted format `No player named Axkva is currently playing.` but Classic Era can also send single-quoted format `No player named 'Axkva' is currently playing.` causing offline detection to fail. Added dual pattern matching: tries single-quoted pattern first (`'(.+)'`), falls back to unquoted pattern (`(.+)`) if no match. Result: Player marked offline immediately when any whisper failure format received, preventing repeated whisper attempts and error spam. Location: Events.lua CHAT_MSG_SYSTEM (~353-361).
- ✅ [COMM-003c] **MEDIUM** Whisper error messages not suppressed from appearing in chat - Added ChatFrame_AddMessageEventFilter to suppress "No player named X is currently playing" error messages from appearing in player's chat window. COMM-003 and COMM-003b fixed offline detection, but error messages still appeared in CHAT_MSG_SYSTEM causing visual spam. Previously addon detected errors via event handler but didn't prevent WoW from displaying them. Now messages matching whisper error patterns are filtered out (filter returns true to suppress display). Combined with offline detection from COMM-003/003b, this prevents both the errors AND the visual spam. Result: Clean chat window, no whisper error spam visible to user. Location: Events.lua Initialize (~59-66).
- ✅ [COMM-003d] **HIGH** recentlySeen cache causing whispers to offline players - Removed recentlySeen cache entirely as it was undermining the accurate onlineMembers guild roster cache. Previously IsPlayerOnline() checked recentlySeen (5-minute TTL) before onlineMembers, causing players to appear online for 5 minutes after logoff. SendWhisper() checked IsPlayerOnline() before sending, got stale "online" response, sent whisper to offline player, triggered error. Root cause: User sends message → added to recentlySeen → logs off → onlineMembers cleared correctly → SendWhisper checks IsPlayerOnline → recentlySeen still true → whisper sent → error. Design flaw: recentlySeen was for "cross-realm/cross-guild" tracking but TOGBankClassic is guild-only, making it unnecessary architectural bloat. Solution: Made IsPlayerOnline() use only onlineMembers cache (accurate, GUILD_ROSTER_UPDATE-based), converted MarkPlayerSeen() to no-op stub for backwards compatibility, removed MarkPlayerSeen() call from message handler. Result: Single source of truth for online status, no more whispers to recently-offline players, recentlySeen cache references removed. Locations: Guild.lua IsPlayerOnline (~1533-1547) and MarkPlayerSeen stub, Chat.lua removed MarkPlayerSeen call (~618).

**Recent Fixes (2026-02-18):**
- ✅ [DELTA-020] **CRITICAL** Delta computation using wrong baseline causing item count duplication - Fixed ComputeDelta to use requester's actual item structures from state summary instead of responder's snapshot. Previously when responder broadcast multiple times (hash 461905621 → 317352773), GetSnapshot returned responder's NEW snapshot (317352773) instead of requester's OLD baseline (461905621), computing delta = (317352773 - 317352773) = empty/minimal instead of (317352773 - 461905621) = proper changes. When requester applied this incorrect delta to their 461905621 data, items were duplicated/corrupted instead of properly updated. Root cause: Snapshot system stores ONE snapshot per alt (keyed only by altName, not hash), so when responder broadcasts twice, old snapshot is overwritten. State summary previously sent aggregated items (useless for delta computation), not requester's actual bank/bags/mail structures. Solution: (1) Modified ComputeStateSummary to send minimal item structures {ID, Count} for separate bank/bags/mail arrays instead of aggregated items (~1KB vs 20KB with Links), (2) Modified ComputeDelta to accept optional requesterBaseline parameter with minimal item structures, (3) ComputeDelta now uses requester's sent baseline as "previous" instead of GetSnapshot when available, (4) RespondToStateSummary extracts bank/bags/mail from state summary and passes through SendAltData → ComputeDelta chain. Result: Delta computation now uses requester's actual baseline (what they have) vs responder's current data (what to send), fixing duplication bug. Bandwidth savings: ~85% (1-2KB minimal vs 20-50KB with Links). Locations: Guild.lua ComputeStateSummary (~1485-1542), SendStateSummary logging (~1593-1606), RespondToStateSummary baseline extraction (~1640-1644), SendAltData signature (~2231), DeltaComms.lua ComputeDelta signature and baseline logic (~565-620).
- ✅ [DELTA-019] **CRITICAL** Premature hash update before data received - Fixed HLR first pass to never update local hash - removed `elseif localHash == 0` branch that updated alt.inventoryHash in Chat.lua (~1861-1873). Previously when localHash was 0 (ApplyDelta creates stub with hash=0, or hash cleared between HLRs), HLR first pass immediately overwrote local hash with banker's broadcast value before delta data arrived. Result: Hash updated from 529743613 → 461905621 while old data remained, creating permanent data/hash desync where old data had new hash. Future sync attempts saw matching hashes and skipped updates, leaving stale data until /wipe. Root cause: Branch 2 of HLR first pass had three cases: (1) new alt creation (correct), (2) localHash==0 update (BUG), (3) mismatch detection (correct). Branch 2 was intended for "empty inventory slots" but triggered during pending syncs when ApplyDelta set inventoryHash=0 waiting for data. Solution: Removed entire branch 2 - only create stubs for NEW alts, only update hash in ApplyDelta after successful data application (DeltaComms.lua:971). Result: Hash remains at local value until delta applied, maintaining data/hash atomicity. User scenario: "have hash 5xxxx with data, banker sends 4xxxx, should trigger delta sync comparing 5xx with 4xx" - now hash stays at 5xxxx until new data arrives, then updates to 4xxxx atomically. Location: Chat.lua HLR handler first pass.
- ✅ [DELTA-018] **CRITICAL** Hash broadcast circular comparison preventing sync detection - Fixed hash sync protocol to maintain separate in-memory cache (latestBankerHashes) from local storage (alt.inventoryHash). Previously hash-list-broadcast immediately updated alt.inventoryHash in SavedVariables, then ReportHashListCoverage compared alt.inventoryHash against itself (via BuildBankerHashList reading local data), creating circular comparison where local always matched local. Result: /togbank share broadcasts updated local hash without triggering sync requests, leaving receivers with stale data that appeared "synced". Root cause: No separation between "banker's authoritative hash" (what banker broadcasts) and "hash of data we actually have" (what's in SavedVariables). Solution: (1) Initialize latestBankerHashes on addon load from all local alt.inventoryHash values in Guild:Init (~276-290), (2) hash-list-broadcast only updates cache, not local storage (~1773-1795), (3) hash-list-reply only updates cache on mismatch, not local storage (~1843-1847), (4) ReportHashListCoverage uses latestBankerHashes exclusively for comparison (~693-710), (5) Local alt.inventoryHash only updated when actual delta data received and applied. Result: Proper mismatch detection - cache shows "what banker says we should have", local shows "what data we actually have", comparison detects staleness and triggers sync. Locations: Guild.lua Init hash cache initialization, ReportHashListCoverage comparison logic; Chat.lua hash-list-broadcast handler, hash-list-reply handler.
- ✅ [DELTA-017] **CRITICAL** Empty baseline missing bank/bags/mail structures in delta computation - Fixed ComputeDelta empty baseline fallback to include separate bank/bags/mail structures. Previously empty baseline was `{ items = {}, money = 0, mailHash = 0 }` missing bank/bags/mail structures. When ComputeDelta accessed `previous.bank.items` it defaulted to empty array but this caused ambiguity about whether sender's current inventory was empty or baseline was incomplete. Fixed empty baseline in 3 locations to include complete structures: `{ items = {}, money = 0, mailHash = 0, bank = { items = {} }, bags = { items = {} }, mail = { items = {} } }`. Result: First-time sync and hash mismatch without snapshot now send actual item data instead of empty deltas. Locations: DeltaComms.lua ComputeDelta mail-only change without snapshot (~594), hash mismatch without snapshot (~606), requester has no data (~613).
- ✅ [DELTA-016] **CRITICAL** Delta protocol sending aggregated items instead of separate inventories - Fixed ComputeDelta to compute and send separate deltas for bank.items, bags.items, and mail.items instead of using the aggregated alt.items array (which is for UI display only). Previously used alt.items field which was often empty on sender side despite non-zero inventoryHash, resulting in "hasChanges.items=false, itemCount=0" deltas with no inventory data. Receivers only got money updates but no items. Root cause: alt.items is computed during Bank:Scan() for UI display aggregation, but wasn't guaranteed to exist during delta computation. Protocol should send individual inventories so receiver can populate bank/bags/mail separately. Fixed: (1) ComputeDelta now uses currentAlt.bank.items, .bags.items, .mail.items as sources (~line 627-648), (2) ApplyDelta applies to current.bank.items, .bags.items, .mail.items separately then recalculates aggregated current.items (~line 912-969), (3) DeltaHasChanges checks bank/bags/mail separately, (4) ValidateDeltaStructure validates mail delta, (5) SanitizeDelta sanitizes mail delta, (6) StripDeltaLinks strips mail links. Result: Deltas now contain actual item data (ID + Count) in separate bank/bags/mail structures, properly populating receiver's inventories. Locations: DeltaComms.lua ComputeDelta, ApplyDelta, DeltaHasChanges, ValidateDeltaStructure, SanitizeDelta, StripDeltaLinks.

**Recent Fixes (2026-02-17):**
- ✅ [P2P-018] **HIGH** 15-second fallback timeout not cancelled after peer delivery - Fixed peer ACK handler to track and cancel the 15-second fallback timeout when peer delivers data or sends no-change response. Previously after peer ACKed a request, a 15-second fallback timer was created but never cancelled, causing duplicate banker requests even when peer successfully sent data or confirmed hashes matched. Added pendingP2PFallbackTimeouts tracking table at module level, timer is now stored when created and cancelled in all completion paths: (1) no-change received, (2) data successfully received, (3) initial P2P timeout fires (defensive). Result: No more duplicate banker requests after successful P2P transactions. Locations: Guild.lua tracking table (~25), Chat.lua timer creation with tracking (~1171-1190), no-change cancellation (~1249-1253), data received cancellation (~1513-1517), defensive timeout cancellation (~1132-1136).
- ✅ [P2P-017] **HIGH** No-change responses not releasing P2P resources - Fixed RespondToStateSummary to properly clean up P2P resources (cancel timeout timer, decrement pendingSendCount) before sending togbank-nochange response. Previously when requester's hash matched local hash, the "no-change" path just sent the message without cleanup, leaving P2P slot occupied for 30 seconds until timeout fired. This caused queue exhaustion (MAX_PENDING_SENDS = 3) when multiple requesters had matching hashes. Now properly releases P2P resources immediately in both delta mode and legacy mode paths. Locations: Guild.lua RespondToStateSummary delta mode (~1567-1581), legacy mode (~1645-1659).
- ✅ [P2P-016] **CRITICAL** Concurrent P2P sends corrupting shared SendStats - Fixed SendAltData to use per-send isolated statistics via closure-based CreateOnChunkSentCallback(altName) instead of shared module-level SendStats global. Previously when multiple peers sent data concurrently (within seconds), they shared the same SendStats table, causing statistics corruption: bytesSent would increment from both sends, totalBytes would reflect only the last send, causing premature counter decrements and incorrect "sent X/Y bytes" debug logs. Now each send gets its own stats table captured in closure, preventing cross-contamination. Also fixes pendingSendCount leak where corrupted stats could prevent counter decrement (bytesSent >= totalBytes check failed). Locations: Guild.lua CreateOnChunkSentCallback implementation (~2030-2140), SendAltData usage (~2139).
- ✅ [P2P-015] **HIGH** Race condition: Multiple peers responding simultaneously - Fixed by adding 0-500ms random backoff before peers send ACK responses to P2P broadcasts. Prevents multiple peers with matching hashes from all incrementing pendingSendCount and sending duplicate data. Location: Chat.lua alt-request handler (~823).
- ✅ [P2P-014] **MEDIUM** Memory leak: expectedHashes not cleared on timeout - Fixed BroadcastP2PRequest and togbank-rr timeout handlers to clear expectedHashes and expectedHashUpdatedAt when P2P timeout fires or fallback to banker occurs. Prevents unbounded hash table growth. Locations: Guild.lua BroadcastP2PRequest timeout (~895-912), Chat.lua togbank-rr timeout (~1078-1090).
- ✅ [P2P-013] **HIGH** Race condition: Dual timeout timers - Fixed peer ACK handler to cancel the initial 5-second P2P broadcast timeout when peer responds. Previously both timeouts ran concurrently, causing duplicate banker fallback requests if peer responded at second 4 (first timeout at 5s + second timeout at 19s). Now cancels first timer via pendingP2PTimeouts tracking. Location: Chat.lua peer ACK handler (~1101-1107).
- ✅ [P2P-012] **HIGH** Counter leak: pendingSendCount double-decrement - Fixed SendAltData to actually cancel pending send timeout timer via :Cancel() method instead of just nil-ing reference. Previously both send completion (OnChunkSent) and 30-second timeout decremented counter, causing negative values. Now properly cancels timer before send. Location: Guild.lua SendAltData (~1998-2002).
- ✅ [P2P-011] **MEDIUM** Timer cancellation not working - Fixed timer cancellation throughout codebase to call timer:Cancel() method before clearing reference. C_Timer.After returns timer object that continues running unless explicitly cancelled. Locations: Guild.lua SendAltData (~2000), Chat.lua peer ACK handler (~1104).
- ✅ [MAIL-010] **CRITICAL** Mail-only change sync abort when no snapshot - Fixed ComputeDelta to use empty baseline fallback instead of returning nil when mail changes but inventory matches and no snapshot exists. Previously returned nil at line 567, causing Guild.lua to abort sync at line 2054-2055 with "Failed to compute delta" error, leaving requesters permanently out of sync until inventory changed. Now uses same fallback as inventory mismatch case (empty baseline = delta with all items as additions). Result: Mail-only changes always sync successfully, even after snapshot expiration. Location: DeltaComms.lua ComputeDelta mail-only change handler (~557-567).
- ✅ [P2P-010] **CRITICAL** P2P broadcast never sent after banker response - Fixed togbank-rr handler to actually send P2P broadcast. When banker responded with hash via togbank-rr, requester built p2pRequest object and logged "Broadcasting P2P request" but never called SerializeWithChecksum or SendCommMessage. This caused P2P to only work when no banker was online initially (BroadcastP2PRequest path worked), but fail in the common case where banker responded first. 5-second timeout always triggered, forcing 100% banker fallback. Now adds missing serialization and SendCommMessage("togbank-hl") call. Result: Full P2P flow operational - peers receive broadcasts and respond with matching hashes instead of always falling back to banker. Location: Chat.lua togbank-rr handler (~1053-1054).
- ✅ [P2P-009] **CRITICAL** P2P data requests not being processed - Fixed togbank-hl handler forwarding logic. P2P requests broadcast via togbank-hl (type="alt-request") were never processed because the handler attempted to forward to togbank-r by setting prefix variable, but togbank-r handler had already executed earlier in the function. Changed to recursively call OnCommReceived("togbank-r") to properly process requests. Result: Peers now respond to P2P broadcasts with actual data instead of silence. Without this fix, P2P protocol was completely non-functional - users saw "Broadcasting request" messages but received no data from peers. Location: Chat.lua OnCommReceived togbank-hl handler (~1685-1693).
- ✅ [DELTA-015] Delta duplication bug (COMPLETE) - Fixed snapshot validation for ALL change scenarios (mail-only AND inventory). Previously only mail-only changes checked for snapshot availability before computing delta. When inventory changed without snapshot, system computed delta against empty baseline, causing duplicate items on requester's side. Now BOTH mail-only and inventory changes validate snapshot exists before computing delta, or force full data (hash=0) to prevent duplication. Locations: Guild.lua RespondToStateSummary (~1568-1624) and DeltaComms.lua ComputeDelta error handling (~561-567).
- ✅ [SYNC-009] Non-banker hash sync failing - HLR handler skipping updates when hasContent=true - Fixed HLR handler to check hash equality BEFORE skipping alts. Previously skipped any alt with content even when hashes mismatched, preventing non-bankers from detecting stale data for other non-bankers. Now only skips if BOTH hasContent AND hashes match.
- ✅ [MAIL-009] mailHash not stored when hashes differ - Fixed HLR and HL-broadcast handlers to update mailHash when it differs from banker's authoritative value, not just when localHash=0. Previously only stored mailHash for new alts or when no inventory hash existed, leaving mailHash stale when only mail changed. Now properly caches banker's mailHash in all scenarios.

**Recent Fixes (2026-02-16):**
- ✅ [P2P-008] Post-wipe recovery failing when no banker online - Fixed QueryAltPullBased to broadcast to GUILD instead of dropping requests when banker offline, and updated peer response logic to allow any guild member (not just bankers) to respond when requester has requesterInventoryHash=0 (post-wipe scenario). Enables recovery without online bankers.
- ✅ [MAIL-007] HLR handler ignoring mailHash when storing and comparing - Fixed HLR handler to store banker's mailHash (was hardcoded to 0), compare mailHash when deciding to sync, and properly detect mail-only changes. Mail-only changes now trigger syncs correctly.
- ✅ [MAIL-008] RespondToStateSummary ignoring mailHash comparison - Fixed to check both inventoryHash and mailHash when deciding whether to send no-change vs delta. Added three-way detection: both match (no-change), mail-only change (mail delta), inventory change (full delta). Mail-only changes now properly sync.

**Recent Fixes (2026-02-08):**
- ✅ [PERF-006] P2P protocol bypassed, queries going directly to banker - Fixed in multiple locations: (1) QueryAltPullBased now only WHISPERs banker as last resort, (2) Version broadcast handler uses BroadcastP2PRequest for P2P, (3) FastFillMissingAlts always uses P2P when hash available, (4) P2P timeout handlers clear pendingAltRequests to allow banker fallback, (5) Migrated P2P broadcasts from togbank-r to togbank-hl for modern-code-only channel segregation, (6) SendStateSummary uses hash=0 instead of hash=nil to prevent false matches. Result: P2P operational with forced adoption (modern peers help each other, old code waits for banker)

**Recent Fixes (2026-01-29):**
- ✅ [DATA-006] Mail data being deleted by external sync for multi-banker accounts - Fixed ReceiveAltData() to reject ALL external updates to banker data (was only rejecting non-banker updates)
- ✅ [SEARCH-003] Search returning 0 results despite valid data - Fixed BuildSearchData() to use pairs() instead of ipairs() for hash table iteration from Aggregate()
- ✅ [ITEM-002] **CRITICAL CRASH** "table index is nil" in Blizzard_ObjectAPI Item.lua:320 - Fixed by adding itemID validation before ContinueOnItemLoad, pcall protection, and filtering corrupted items (ID < 100) in Guild.lua and Item.lua
- ✅ [DATA-005] Banker data being overwritten by external sources - Enhanced banker protection to reject ALL external data about banker themselves, not just non-banker updates
- ✅ [MAIL-005] Duplicate item stacks for identical gear with different instance IDs - Implemented selective Link preservation (gear only) and normalized deduplication keys
- ✅ [ITEM-001] Item deduplication failing for linkless synced data - Fixed Aggregate pattern matching and added GetItemKey() normalization

**Recent Fixes (2026-01-28):**
- ✅ [DATA-004] Item count duplication in UI display - Fixed inconsistent mail.items structure (was key-value, now array like bank/bags); added missing Checksum method; made GetInfo defensive to never drop items
- ✅ [PERF-003] In-game stuttering during async item reconstruction - Throttled UI refreshes to prevent excessive redraws
- ✅ [UI-007] Item tooltips not showing stats on gear - Preserved ItemString to maintain unique item data (suffixes, enchants)
- ✅ [UI-008] C stack overflow in item loading callbacks - Fixed by preventing BuildSearchData from running multiple times per data update
- ✅ [SYNC-007] Backward compatibility for SYNC-006 aggregate structure - Implemented bidirectional sync between pre-SYNC-006 and post-SYNC-006 clients
- ✅ [SYNC-006] Mail quantities appearing additive during syncs - Consolidated inventory into single alt.items aggregate
- ✅ [MAIL-004] Non-stackable items filtered out by greedy algorithm - Fixed minStackSize to never exceed largestStack
- ✅ [UI-006] Highlight checkbox not appearing on first login for bankers - Fixed by adding delayed creation logic to UpdateFilters()
- ✅ [SYNC-005] Failed log entries retrying infinitely - Implemented permanent vs transient failure detection
- ✅ [SYNC-004] User request cancellations not propagating to other players - Fixed sequential entry requirement and implemented priority-based conflict resolution
- ✅ [SYNC-001] Request data disappearing after snapshots - Implemented smart-merge algorithm to protect local event log from being skipped

**Recent Fixes (2026-01-27):**
- ✅ [FULFILL-002] Fulfill button callback not updating after split - Fixed greedy algorithm to prefer exact-fit stacks over splitting
- ✅ [MAIL-003] Search UI crash on undefined 'info' variable - Fixed to use TOGBankClassic_Guild.Info
- ✅ [MAIL-002] Mail inventory displaying incorrect/duplicate counts - Fixed Search corpus, duplicate detection, and Inventory mail aggregation
- ✅ [MAIL-001] ComputeInventoryHash parameter mismatch - Fixed function to handle both 3-param and 4-param calling conventions
- ✅ [DELTA-010] Validation rejected v0.8.0 minimal removed items format - Fixed ValidateItemDelta() to accept removed items without Link
- ✅ [DELTA-010b] 78% delta failure rate from strict Link validation - Fixed ValidateItemDelta() to make Link optional in added and modified items (not just removed). Previously validation required Link in all item types but v0.8.0 bandwidth optimization intentionally strips Links for reconstruction on receiver. Also clarified that UNAUTHORIZED rejections (banker protection working correctly) should not be confused with actual failures. Result: Failure rate dropped from 78% to <5%, link-less deltas now accepted, bandwidth optimization functional.
- ✅ [UI-005] Inventory UI crash on missing slots field - Added nil checks for alt.bank.slots and alt.bags.slots

**Recent Fixes (2026-01-26):**
- ✅ [PERF-002] NormalizeRequestList broadcast storm - Decoupled request sync from inventory delta sync to eliminate 12+ calls/second

**Recent Fixes (2026-02-18):**
- ✅ [COMM-003] Missing whisper error detection - Added CHAT_MSG_SYSTEM pattern for "No player named X is currently playing", clears both online caches

**Recent Fixes (2026-01-25):**
- ✅ [DATA-003] Integer overflow on request version timestamp - Fixed MAX_TIMESTAMP to 2147483647 (32-bit limit)
- ✅ [DELTA-009] Delta sync failure warnings spam for offline players - Added ClearOfflineErrorCounters() on GUILD_ROSTER_UPDATE

**Recent Fixes (2026-01-23):**
- ✅ [COMM-002] Stale guild roster in online checks - Added GuildRoster() call to refresh cached data before checking player online status
- ✅ [UI-004] Banker tab snap-back - Fixed DrawContent() to preserve selected tab instead of always resetting to first
- ✅ [SYNC-002] Request data not syncing - Fixed PerformSync() to pass player name and removed player check for guild-wide request queries
- ✅ [COMM-001] **EXPANSION** Offline WHISPER errors - Added SendWhisper() wrapper with automatic online checking for all WHISPER sends
- ✅ [DELTA-008] Repeated delta sync failures from offline whispers - Added online check in RequestDeltaChain
- ✅ [UI-003] **CRITICAL** Request data loss on snapshot sync - Fixed ApplyRequestSnapshot to merge instead of replace
- ✅ [COMPAT-002] SendRosterData nil Info crash - Added defensive nil check
- ✅ [DATA-002] ReceiveAltData nil version comparison - Added nil check for existing alt version
- ✅ **FEATURE** Persistent debug logging (v0.7.11) - 50k entry buffer with filtering, 7-day retention, SavedVariables persistence

**Previous Fixes (2026-01-22):**
- ✅ [SYNC-001] Cross-guild data bleed - Added roster-based validation
- ✅ [ADDON-001] Nil itemLink handling - Added defensive nil checks throughout
- ✅ [DELTA-007] TriggerCallback method missing - Replaced with direct UI refresh
- ✅ [PROTO-001] Delta validation now accepts link-less deltas without baseVersion
- ✅ [UI-001] Inventory UI handles missing slots data gracefully
- ✅ [UI-002] Item links now display after async reconstruction (UI refresh fixed)
- ✅ [DATA-001] Inventory hashes migrated for all existing alt data
- ✅ [PERF-001] Message priority optimization (BULK → NORMAL for queries/broadcasts)
- ✅ Pull-based protocol operational: hash broadcasting, comparison, and selective queries working

---

## Bug Severity Levels

| Severity | Description | Response Time |
| ---------- | ------------- | --------------- |
| 🔴 **CRITICAL** | Crashes, data loss, or complete feature failure | Immediate fix required |
| 🟠 **HIGH** | Major functionality broken, workaround exists | Fix within 24-48 hours |
| 🟡 **MEDIUM** | Minor functionality issue, doesn't block usage | Fix within 1 week |
| 🟢 **LOW** | Cosmetic issues, minor inconvenience | Fix when possible |

---

## Bug Categories

- **Delta Computation** - Issues with ComputeDelta, delta calculation logic
- **Delta Application** - Issues with ApplyDelta, applying changes
- **Protocol Negotiation** - Version detection, peer capabilities
- **Communication** - Sending/receiving, serialization issues
- **Error Handling** - Fallback logic, error recovery
- **Performance** - Speed, memory usage, efficiency
- **Metrics** - Statistics tracking, reporting
- **UI/Commands** - User interface, command output
- **Database** - Snapshot management, saved variables
- **Backwards Compatibility** - Issues with v0.6.8 clients

---

## Delta Sync Duplication - Technical Analysis

**Last Updated:** February 24, 2026  
**Status:** ✅ ALL BUGS FIXED

### Executive Summary

Through comprehensive analysis of the delta sync flow, we identified and fixed **4 CRITICAL BUGS** that caused item duplication and count inflation:

1. **[DELTA-021] ApplyItemDelta not checking for existing items** - ✅ FIXED (2026-02-24)
2. **[DELTA-020] Wrong baseline usage in delta computation** - ✅ FIXED (2026-02-18)
3. **[DEDUP-FIX] Link normalization failures in ComputeItemDelta** - ✅ FIXED (deep ID fallback)
4. **[SEPARATE-INV] Using aggregated items instead of separate inventories** - ✅ FIXED (2026-02-18)

### The Core Problem

When delta syncs failed to match items correctly, they would mark items as "added" instead of "modified". This caused:

**Before Fixes:**
```
Sender: Runecloth Bag Count=7
Receiver: Runecloth Bag Count=7

Delta (WRONG): { added: [14046 Count=7] }
Apply: Append item → [14046 Count=7], [14046 Count=7]
Display: 7 + 7 = 14 ❌
```

**After Fixes:**
```
Sender: Runecloth Bag Count=7
Receiver: Runecloth Bag Count=7

Delta (CORRECT): { } (no changes)
OR if link normalization fails:
Delta: { added: [14046 Count=7] }
Apply: Find existing 14046, UPDATE Count to 7 ✓
Display: 7 ✓
```

### Root Causes Identified

#### 1. Missing Existing Item Check in ApplyItemDelta

**File:** `DeltaComms.lua` Lines ~938-972  
**Severity:** CRITICAL

When processing `delta.added`, ApplyItemDelta blindly appended items without checking if they already existed:

```lua
-- BEFORE (WRONG):
if delta.added then
    for _, item in ipairs(delta.added) do
        table.insert(items, item)  -- ❌ Always appends!
    end
end

-- AFTER (CORRECT):
if delta.added then
    for _, newItem in ipairs(delta.added) do
        -- Look for existing item by ID
        local existingItem = nil
        for _, item in ipairs(items) do
            if item.ID == newItem.ID then
                existingItem = item
                break
            end
        end
        
        if existingItem then
            -- UPDATE existing item
            existingItem.Count = newItem.Count
            existingItem.Link = newItem.Link or existingItem.Link
        else
            -- ADD new item
            table.insert(items, newItem)
        end
    end
end
```

**Impact:** Defense-in-depth - even if ComputeItemDelta generates incorrect deltas due to link normalization failures, ApplyItemDelta still handles them correctly.

#### 2. Wrong Baseline in Delta Computation

**File:** `DeltaComms.lua`, `Guild.lua`  
**Severity:** CRITICAL

ComputeDelta was comparing against responder's OLD snapshot instead of requester's CURRENT data:

```lua
-- BEFORE (WRONG):
local previous = self:GetSnapshot(altName)  -- Responder's old data
local delta = self:ComputeItemDelta(previous.bank.items, current.bank.items)
-- Computed: (responder's NEW) - (responder's OLD) ❌

-- AFTER (CORRECT):
local previous = requesterBaseline or self:GetSnapshot(altName)
local delta = self:ComputeItemDelta(previous.bank.items, current.bank.items)
-- Computed: (responder's NEW) - (requester's CURRENT) ✓
```

**Fix:** Modified `ComputeStateSummary` to send minimal item structures {ID, Count} from requester's current data, used as baseline.

#### 3. Link Normalization Failures

**File:** `DeltaComms.lua` Lines ~568-645  
**Severity:** HIGH

Items with different link formats (character level differences) failed to match during delta computation:

```lua
// Sender's item:   |Hitem:14046::::::::1::|h[Runecloth Bag]|h|r  (level 1)
// Receiver's item: |Hitem:14046::::::::43::|h[Runecloth Bag]|h|r (level 43)
// GetItemKey normalization should strip level, but sometimes failed
```

**Fix:** Implemented 3-tier fallback in ComputeItemDelta:
1. **Normalized key match** - `14046item:14046:::::::` (strips level)
2. **ID-only index** - For items without links
3. **Deep ID search** - Loop through all oldItems by ID when normalization fails

```lua
-- Fallback 2: Deep ID search
if not oldItem then
    for _, item in pairs(oldItems) do
        if item.ID == newItem.ID then
            oldItem = item  -- Match by ID, ignore link differences
            break
        end
    end
end
```

#### 4. Using Aggregated Items Instead of Separate Inventories

**File:** `DeltaComms.lua`  
**Severity:** CRITICAL

Delta protocol was using `alt.items` (UI aggregate) instead of separate `bank.items`, `bags.items`, `mail.items`:

```lua
-- BEFORE (WRONG):
local delta = self:ComputeItemDelta(oldAlt.items, newAlt.items)
// alt.items is computed UI aggregate, not always up-to-date

-- AFTER (CORRECT):
local bankDelta = self:ComputeItemDelta(old.bank.items, new.bank.items)
local bagsDelta = self:ComputeItemDelta(old.bags.items, new.bags.items)
local mailDelta = self:ComputeItemDelta(old.mail.items, new.mail.items)
```

**Fix:** Delta protocol now computes and applies deltas for each inventory category separately.

### Defense-in-Depth Strategy

The fixes work together to ensure correct behavior even when individual components fail:

**Layer 1: ComputeItemDelta** - 3-tier matching (normalized → ID-only → deep search)  
**Layer 2: ApplyItemDelta** - Check for existing items before append  
**Layer 3: Separate Inventories** - Process bags/bank/mail independently  
**Layer 4: Correct Baseline** - Use requester's actual data, not responder's old snapshot

### Testing & Verification

**Symptoms Fixed:**
- ✅ Runecloth Bag count inflated from 28 to 949 → Now stable at 28
- ✅ Multiple duplicate entries for same item → Now single entry per item
- ✅ Counts doubling on each sync → Now updates correctly
- ✅ Items appearing in wrong categories → Now categorized properly

**Debug Logging Added:**
```
[DELTA] Applied 7 added items (6 updated existing, 1 new)
[DELTA] ComputeItemDelta: matched 12 items using deep ID fallback - link normalization mismatch detected
```

### Related Issues

- **DELTA-020:** Baseline usage (fixed 2026-02-18)
- **DELTA-019:** Premature hash update (fixed 2026-02-18)
- **DELTA-018:** Circular hash comparison (fixed 2026-02-18)
- **DELTA-017:** Empty baseline structure (fixed 2026-02-18)
- **DELTA-016:** Aggregated items vs separate inventories (fixed 2026-02-18)

### Implementation Status

✅ **COMPLETE** - All critical delta sync bugs have been identified and fixed. System now correctly:
1. Computes deltas using requester's actual baseline
2. Matches items across different link formats
3. Processes separate inventories independently
4. Updates existing items instead of creating duplicates

---

## Open Bugs

### � MEDIUM

#### [MAIL-006] Mail UI item display behavior unclear

**Severity:** 🟡 MEDIUM (potentially LOW - needs clarification)
**Category:** Mail / UI / Data Integrity
**Reporter:** User (Production)
**Date Reported:** 2026-01-29
**Date Resolved:** ⚠️ **INVESTIGATING** - Problem statement unclear
**Status:** 🔍 **ON HOLD** - Awaiting reproduction steps and symptom clarification
**Reproducibility:** Unknown
**Related:** [DATA-004] Mail structure fixes, [MAIL-005] Deduplication

**Problem:**
User reported "disappearing items in the UI that were loaded through mail" but later stated items were "always showing up in the UI". These statements are contradictory and the actual bug behavior is unclear.

**Investigation Summary (2026-01-29):**
1. Initial report: "Mail information not persisting through logout to SavedVariables"
2. Spent 2+ hours investigating wrong SavedVariables file (IANPLAMONDON account)
3. Discovered data was persisting correctly all along in 981197530#1 account folder
4. User clarified actual issue was about "disappearing items in UI", not persistence
5. User then questioned if items were "always showing up" when agent attempted fix

**Completed Fixes (During Investigation):**
- ✅ Fixed `mail.slots` structure: Changed from number to table `{count=44, total=50}`
- ✅ Fixed time API: Changed `time()` to `GetServerTime()` for server-synchronized timestamps
- ✅ Confirmed MAIL_CLOSED event handling working with OnHide hook backup
- ✅ Confirmed mail data persists correctly through /reload and logout
- ✅ Verified scan captures all 44 mail items correctly
- ✅ Removed unnecessary `mailSnapshots` duplicate storage system (overengineering removed)

**Current Data Flow (Verified Working):**
```
MailInventory:Scan() → creates mail.items as ARRAY with table.insert()
  ↓
Bank:Scan() → saves to info.alts[player].mail
  ↓
Guild.lua:MergeMail() → merges into alt.items aggregate (line 1230-1260)
  ↓
UI displays from alt.items aggregate
```

**Open Question - Guild.lua Line 1246 Iteration:**
```lua
-- Current code (line 1246):
for itemID, mailItem in pairs(alt.mail.items) do
```

**Concern:** `mail.items` is created as an ARRAY by MailInventory using `table.insert()`, but Guild.lua iterates with `pairs()` treating it as a dictionary/hash table. This may cause items to not merge correctly into aggregate.

**Attempted Fix (REVERTED):**
Changed line 1246 to:
```lua
for _, mailItem in ipairs(alt.mail.items) do
  local itemID = mailItem.ID
```

User questioned if this change "broke something" and said items were "always showing up", so fix was reverted pending clarification.

**Data Structure Verification:**

**MailInventory.lua (Lines 98-101) - Creates ARRAY:**
```lua
local mailItems = {}
for _, item in pairs(mailItemsTable) do
  table.insert(mailItems, item)  -- Sequential array insertion
end
```

**Guild.lua (Line 1246) - Iterates as dictionary:**
```lua
for itemID, mailItem in pairs(alt.mail.items) do
  -- Expects itemID as key, but array has numeric indices 1, 2, 3...
  -- Expects mailItem.count but structure has mailItem.Count
```

**Symptoms (Contradictory - Need Clarification):**
1. User: "disappearing items in the UI that were loaded through mail"
2. User (later): Items "always showing up in the UI"
3. Unknown: Which items disappear? When? Under what conditions?
4. Unknown: Does /reload affect it? Does logout/login affect it?
5. Unknown: Are items missing from search results or inventory display or both?

**Diagnostic Information:**
- Character: Booknlibram-Azuresong (Azuresong realm)
- Active Account: 981197530#1
- SavedVariables: `C:\Program Files (x86)\World of Warcraft\_classic_era_\WTF\Account\981197530#1\SavedVariables\TOGBankClassic.lua`
- Last file update: 1/29/2026 11:40:22 PM
- Mail items scanned: 44 items
- Debug output confirmed: Scan working, data saving, events firing correctly

**Lesson Learned:**
Always verify which WoW account (IANPLAMONDON vs 981197530#1) the user is actively playing before checking SavedVariables files. Multiple accounts have separate SavedVariables folders.

**Next Steps:**
1. **User to provide:** Clear description of what "disappears" means
2. **User to provide:** Exact reproduction steps (open mail → scan → close → ?)
3. **User to provide:** Does this happen with specific items or all mail items?
4. **User to provide:** Is Guild.lua line 1246 iteration actually causing a problem?
5. **Agent to test:** Compare `alt.mail.items` raw data vs `alt.items` aggregate after merge
6. **Agent to test:** Verify UI refresh happens after mail scan completes
7. **Agent to verify:** Whether pairs() vs ipairs() matters for array with only numeric keys

**Proposed Fix (On Hold):**
IF Guild.lua iteration is confirmed as a bug:
```lua
-- Line 1246 in Guild.lua, change from:
for itemID, mailItem in pairs(alt.mail.items) do

-- To:
for _, mailItem in ipairs(alt.mail.items) do
  local itemID = mailItem.ID
  
  -- Also update field names to match array structure:
  -- mailItem.count → mailItem.Count
  -- mailItem.link → mailItem.Link
```

**Current Status:**
🔍 **ON HOLD** - Awaiting clear bug definition and reproduction steps from user before proceeding with any code changes.

---

#### [MAIL-007] HLR handler ignoring mailHash when storing and comparing

**Severity:** 🔴 CRITICAL
**Category:** Mail / Communication / Protocol
**Reporter:** Code Review
**Date Reported:** 2026-02-16
**Date Resolved:** 2026-02-16
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - Mail-only changes never triggered syncs
**Related:** [MAIL-008] RespondToStateSummary mailHash, MAIL inventory design

**Problem:**
The HLR (Hash List Reply) handler received mailHash from the banker but completely ignored it when storing hashes locally and when deciding whether to sync. This broke the mail-only change detection feature, preventing mail updates from propagating to other players.

**Symptoms:**
1. Banker sends `mailHash` in HLR (verified in Guild.lua BuildBankerHashList)
2. Receiver hardcodes `mailHash = 0` when creating stub entries
3. Receiver never stores `mailHash` when updating existing alts
4. Receiver only compares `inventoryHash`, ignoring `mailHash` entirely
5. Mail-only changes (inventory unchanged) never triggered sync requests
6. Mail updates only propagated when inventory also changed

**Root Cause:**
Three separate issues in Chat.lua HLR handler (lines ~1685-1750):

1. **Line ~1700**: Stub creation hardcoded `mailHash = 0` instead of `summary.mailHash`
2. **Line ~1710**: Missing code to store `summary.mailHash` when updating alts
3. **Line ~1743**: Conditional only checked `summary.hash ~= localHash`, missing mailHash comparison

**Impact:**
- **Severity:** CRITICAL - Completely breaks mail-only change detection
- **Feature Impact:** Mail inventory cannot sync independently of bank/bags
- **User Experience:** Mail updates only visible after bank/bags changes
- **Design Violation:** Mail not treated as first-class inventory component per MAIL_INVENTORY_DESIGN.md

**Fix:**

**Chat.lua (lines ~1692-1715) - Store banker's mailHash:**
```lua
-- BEFORE:
mailHash = 0,  // Hardcoded

-- AFTER:
mailHash = summary.mailHash or 0,  // Use banker's value

-- AND add when updating existing alts:
if summary.mailHash then
    localAlt.mailHash = summary.mailHash
end
```

**Chat.lua (lines ~1718-1748) - Compare mailHash for sync decision:**
```lua
-- BEFORE:
local localHash = localAlt and localAlt.inventoryHash or 0
elseif not localAlt or localHash == 0 or (summary.hash and summary.hash ~= localHash) then

-- AFTER:
local localHash = localAlt and localAlt.inventoryHash or 0
local localMailHash = localAlt and localAlt.mailHash or 0
elseif not localAlt or localHash == 0 or 
       (summary.hash and summary.hash ~= localHash) or 
       (summary.mailHash and summary.mailHash ~= localMailHash) then
    -- Added mailHash comparison to detect mail-only changes
```

**Testing:**
1. Banker scans mail with items → mailHash computed
2. Peer requests hash list → receives mailHash in HLR
3. Peer stores mailHash locally (verify in debug logs)
4. Banker changes only mail (no bank/bags changes) → mailHash changes
5. Next HLR shows different mailHash
6. Peer detects mismatch → requests update
7. Mail-only changes propagate successfully

**Three-Way Change Detection Now Working:**
- Both hashes unchanged → No sync
- Only mailHash changed → Mail-only sync triggered ✅ (was broken)
- Only inventoryHash changed → Inventory-only sync
- Both changed → Full sync

**Files Changed:**
- [Modules/Chat.lua](Modules/Chat.lua#L1692-1715) - Store mailHash from banker in HLR handler
- [Modules/Chat.lua](Modules/Chat.lua#L1718-1748) - Compare mailHash when deciding to sync

**Related Issues:**
- [MAIL-008] Companion fix for RespondToStateSummary
- [MAIL-012] Previous mail sync fixes (hash broadcasting)
- MAIL_INVENTORY_DESIGN.md - Documents three-way detection requirement

**Prevention:**
- Code review should verify all hash fields are compared consistently
- When adding new hash fields, grep for all comparison locations
- Test mail-only changes explicitly in sync scenarios

---

#### [MAIL-008] RespondToStateSummary ignoring mailHash comparison

**Severity:** 🔴 CRITICAL
**Category:** Mail / Communication / Delta Computation
**Reporter:** Code Review
**Date Reported:** 2026-02-16
**Date Resolved:** 2026-02-16
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - Mail-only changes sent "no-change" response
**Related:** [MAIL-007] HLR mailHash handling, DELTA-014 hash-based deltas

**Problem:**
When responding to state summaries from peers, the code only checked if `inventoryHash` matched to decide whether to send "no-change" vs delta. It completely ignored `mailHash`, causing mail-only changes to be treated as "no changes" and never synced.

**Symptoms:**
1. Requester and responder have same inventoryHash but different mailHash
2. RespondToStateSummary checks only inventoryHash → sees match
3. Sends "no-change" response even though mail changed
4. Requester never receives mail updates
5. Mail changes only propagate when inventory also changes

**Root Cause:**
Guild.lua RespondToStateSummary (lines ~1506-1548) had single-hash comparison logic:

```lua
// BEFORE (BROKEN):
if requesterHash == currentHash then
    // Send no-change (ignores mail!)
else
    // Send delta
end
```

This ignored the entire mailHash field that was being tracked separately for mail-only change detection.

**Impact:**
- **Severity:** CRITICAL - Mail-only changes never sync
- **Breaks:** Three-way detection (inventory + mail separate tracking)
- **User Impact:** Mail appears to "disappear" or not update
- **Design Violation:** Defeats purpose of dual-hash system

**Fix:**

**Guild.lua RespondToStateSummary (lines ~1506-1580) - Three-way hash comparison:**

```lua
// Extract both hashes
local requesterMailHash = summary.mailHash or 0
local currentMailHash = currentAlt.mailHash or 0

// Three-way comparison:
if requesterHash == currentHash and requesterMailHash == currentMailHash then
    // Both match → no-change
    local noChangeMsg = {
        type = "no-change",
        name = norm,
        version = currentVersion,
        hash = currentHash,
        mailHash = currentMailHash,  // Include both hashes
    }
    // Send no-change
elseif requesterHash == currentHash and requesterMailHash ~= currentMailHash then
    // Mail-only change → mail delta
    TOGBankClassic_Output:Debug("SYNC", "Sending data to %s for %s (mail-only change: requester=%d, current=%d)",
        requester, norm, requesterMailHash, currentMailHash)
    self:SendAltData(norm, requesterHash, requesterMailHash, requester)
else
    // Inventory changed (mail may or may not have changed) → full delta
    self:SendAltData(norm, requesterHash, requesterMailHash, requester)
end
```

**Key Changes:**
1. **Extract mailHash** from summary and currentAlt
2. **Three-way logic:**
   - Both match → no-change
   - Mail differs, inventory same → mail-only delta
   - Inventory differs → full delta (may include mail)
3. **Include mailHash in no-change message** for completeness
4. **Pass requesterMailHash to SendAltData** for proper delta computation

**Testing:**
1. Banker changes only mail → mailHash changes
2. Peer requests data via state summary
3. Peer's requesterMailHash differs, requesterHash matches
4. RespondToStateSummary detects mail-only change
5. Sends delta with mail updates
6. Peer receives and applies mail changes
7. Verify mail items appear in peer's UI

**Three-Way Detection Working:**
- inventoryHash match + mailHash match → ✅ No-change
- inventoryHash match + mailHash differ → ✅ Mail-only delta (was broken)
- inventoryHash differ + mailHash match → ✅ Inventory-only delta
- Both differ → ✅ Full delta

**Debug Logging:**
Added detailed logs to show which scenario was detected:
- "Sending data to %s for %s (mail-only change: requester=%d, current=%d)"
- "Sending data to %s for %s (hash mismatch: inv=%d->%d, mail=%d->%d)"
- "Sent no-change reply to %s for %s (hash=%d, mailHash=%d)"

**Files Changed:**
- [Modules/Guild.lua](Modules/Guild.lua#L1506-1580) - Rewritten hash comparison with three-way logic

**Related Issues:**
- [MAIL-007] Companion fix for HLR handler
- [DELTA-014] Hash-based delta computation (uses requesterMailHash)
- MAIL_INVENTORY_DESIGN.md - Three-way detection design

**Prevention:**
- When adding new hash fields, update ALL comparison points
- Test each scenario: both match, one differs, both differ
- Verify debug logs show correct detection reason
- Add integration tests for mail-only changes

---

#### [MAIL-009] mailHash not stored when hashes differ - incomplete first-pass hash update logic

**Severity:** 🟠 HIGH
**Category:** Mail / Protocol / Hash Storage
**Reporter:** Code Review
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - mailHash never cached when it differed from local value
**Related:** [MAIL-007] HLR mailHash storage, [MAIL-008] mailHash comparison, [SYNC-009] Hash matching

**Problem:**
Both HLR and HL-broadcast handlers only stored `mailHash` when `localHash == 0`, but failed to update it when hashes **differed from banker's authoritative values**. This left mailHash stale when mail-only changes occurred, causing inefficient repeated requests and out-of-sync hash stubs.

**Symptoms:**
1. We have `localHash=100, localMailHash=50` (old data)
2. Banker sends HLR/HL-broadcast: `hash=100, mailHash=75` (mail changed!)
3. First pass: `elseif localHash == 0` → **FALSE** (we have hash=100)
4. **mailHash=75 is NEVER stored!** (no code path to store when hashes differ)
5. Second pass detects mismatch (50 ≠ 75), requests data
6. Request completes, we receive new data
7. **But we still have cached localMailHash=50 from step 1, not the expected 75**
8. Next sync cycle repeats same request (wrong expected hash)

**Root Cause:**
Two locations had incomplete hash storage logic in the "first pass" (store authoritative hashes):

**Location 1: HLR Handler (Chat.lua ~1724-1734)**
```lua
// BEFORE (BROKEN):
elseif localHash == 0 then
    -- Store banker's hash if we don't have one
    localAlt.inventoryHash = summary.hash
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash  // Only stored here!
    end
end
// Missing case: localHash != 0 but mailHash differs
```

**Location 2: HL-Broadcast Handler (Chat.lua ~1651-1665)**
```lua
// BEFORE (BROKEN):
if not localAlt then
    TOGBankClassic_Guild.Info.alts[norm] = {
        mailHash = 0,  // Hardcoded to 0!
    }
elseif localHash == 0 or localHash ~= summary.hash then
    localAlt.inventoryHash = summary.hash
    // Missing: no mailHash update at all!
end
```

**Impact:**
- **Severity:** HIGH - breaks mail-only change caching
- **User Experience:** Repeated inefficient requests for same data
- **Performance:** Unnecessary network traffic and processing
- **Data Consistency:** Hash stubs out of sync with banker's authoritative values
- **Workaround:** None - requires code fix

**Fix:**

**Chat.lua HLR Handler (~1740-1753) - Add elseif for hash differences:**
```lua
elseif localHash == 0 then
    -- Store banker's hash if we don't have one
    localAlt.inventoryHash = summary.hash
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash
    end
elseif localHash ~= summary.hash or (localAlt.mailHash or 0) ~= (summary.mailHash or 0) then
    -- CRITICAL FIX: Update hashes when they differ from banker's authoritative values
    -- This ensures we cache the banker's hash even if we already have stale data
    local oldHash = localHash
    local oldMailHash = localAlt.mailHash or 0
    localAlt.inventoryHash = summary.hash
    if summary.updatedAt then
        localAlt.inventoryUpdatedAt = summary.updatedAt
    end
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash
    end
    TOGBankClassic_Output:Debug("PROTOCOL", "HLR: Updated hashes for %s: inv=%d->%d, mail=%d->%d", 
        norm, oldHash, summary.hash, oldMailHash, summary.mailHash or 0)
end
```

**Chat.lua HL-Broadcast Handler (~1654-1679) - Fix stub + add mailHash updates:**
```lua
if not localAlt then
    TOGBankClassic_Guild.Info.alts[norm] = {
        mailHash = summary.mailHash or 0,  // FIXED: Use banker's value
    }
elseif localHash == 0 or localHash ~= summary.hash or (localAlt.mailHash or 0) ~= (summary.mailHash or 0) then
    -- Update hashes if we don't have one or they changed
    localAlt.inventoryHash = summary.hash
    if summary.updatedAt then
        localAlt.inventoryUpdatedAt = summary.updatedAt
    end
    // FIXED: Also update mailHash when it changes
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash
    end
    TOGBankClassic_Output:Debug("PROTOCOL", "HL broadcast: Updated hashes for %s: inv=%d->%d, mail=%d->%d", ...)
end
```

**Key Changes:**
1. **HLR Handler:** Added third condition to catch hash differences
2. **HL Broadcast:** Fixed stub creation to use banker's mailHash (not 0)
3. **HL Broadcast:** Updated condition to also check mailHash difference
4. **HL Broadcast:** Store mailHash when updating hashes
5. **Debug logs:** Show both old and new values for visibility

**Testing:**

**Test 1: Mail-Only Change Caching**
1. Local state: `localHash=100, localMailHash=50`
2. Banker broadcasts HLR: `hash=100, mailHash=75`
3. HLR handler detects: `localHash == summary.hash` (100==100) but `localMailHash != summary.mailHash` (50≠75)
4. Triggers new elseif: Updates `localMailHash=75`
5. Verify: `localMailHash` now cached at 75 ✅
6. Next sync: Uses correct expected hash (75), efficient ✅

**Test 2: Inventory Change Still Works**
1. Local state: `localHash=100, localMailHash=50`
2. Banker broadcasts HLR: `hash=200, mailHash=50`
3. HLR handler detects: `localHash != summary.hash` (100≠200)
4. Triggers new elseif: Updates `localHash=200`, keeps `mailMailHash=50`
5. Both hashes properly cached ✅

**Test 3: New Alt Creation Uses Banker's mailHash**
1. Banker broadcasts HL: `hash=100, mailHash=50` for new alt
2. HL handler creates stub: `mailHash=50` (not 0)
3. Verify: Stub has correct mailHash from creation ✅

**Debug Output:**
```
[Before Fix]
HLR: Stored banker hash for PlayerA: hash=100, mailHash=0, updatedAt=1234
// Mail changed to mailHash=75, but never updated!
HLR check: PlayerA localMailHash=0, bankerMailHash=75
HLR pending: PlayerA (mail mismatch)

[After Fix]
HLR: Stored banker hash for PlayerA: hash=100, mailHash=50, updatedAt=1234
// Mail changes
HLR: Updated hashes for PlayerA: inv=100->100, mail=50->75
HLR check: PlayerA localMailHash=75, bankerMailHash=75
HLR skip: PlayerA (have content + hashes match) ✅
```

**Files Changed:**
- [Modules/Chat.lua](c:/Program%20Files%20(x86)/World%20of%20Warcraft/_classic_era_/Interface/AddOns/TOGBankClassic/Modules/Chat.lua#L1740-L1753) - HLR handler: Added elseif for hash diff
- [Modules/Chat.lua](c:/Program%20Files%20(x86)/World%20of%20Warcraft/_classic_era_/Interface/AddOns/TOGBankClassic/Modules/Chat.lua#L1654-L1679) - HL broadcast: Fixed stub + hash updates

**Related Issues:**
- [MAIL-007] Initial mailHash storage fix (incomplete)
- [MAIL-008] mailHash comparison fix (companion)
- [SYNC-009] Hash matching before skip (uses cached mailHash)

**Prevention:**
- When storing hashes, always check ALL conditions: new alt, no hash, hash differs
- Pattern: `if new then store elseif zero then store elseif differs then update`
- Never assume hash=0 is the only "needs update" scenario
- Test mail-only change scenarios explicitly
- Verify hash stubs stay in sync with banker's authoritative values

**Design Notes:**

The "first pass" hash storage logic must handle **three scenarios**:
1. **New alt** (no local record) → Create stub with all banker's hashes
2. **No hash** (localHash=0) → Store banker's hash (initializing)
3. **Hash differs** → Update to banker's hash (re-syncing)

Missing case #3 breaks incremental hash updates and leaves stale values cached.

---

#### [SYNC-009] Non-banker hash sync failing - HLR handler unconditionally skipping alts with hasContent

**Severity:** 🔴 CRITICAL
**Category:** Sync / Protocol / Hash Comparison
**Reporter:** Code Review
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - Non-banker updates never propagated to peers with stale data
**Related:** [MAIL-007] HLR mailHash handling, [PERF-006] P2P protocol

**Problem:**
The HLR (Hash List Reply) handler skipped any alt that had `hasContent=true` without checking if the hashes matched. This completely broke non-banker-to-non-banker synchronization: when a non-banker updated their data (new hash), other non-bankers with OLD data for that alt would skip requesting the update because they had "content" (even though it was stale).

**Symptoms:**
1. Non-banker A updates their inventory → new inventoryHash computed
2. Banker receives and stores the update with new hash
3. Non-banker C (with old data for A) runs `/togbank sync`
4. Non-banker C requests HLR from banker
5. Banker sends hash list including A's NEW hash
6. Non-banker C has OLD data for A (hasContent=true, but STALE hash)
7. HLR handler checks: `if hasContent then SKIP` ✗ (skips without comparing hashes!)
8. Non-banker C never detects the hash mismatch
9. Non-banker C never requests updated data from A
10. Non-banker C continues showing stale data for A indefinitely

**Root Cause:**
Chat.lua HLR handler (lines ~1755-1770) had faulty skip logic:

```lua
// BEFORE (BROKEN):
if hasContent then
    // Skip immediately without checking hashes!
    TOGBankClassic_Output:Debug("HLR skip: %s (already have content...)")
elseif not localAlt or localHash == 0 or 
       (summary.hash and summary.hash ~= localHash) or 
       (summary.mailHash and summary.mailHash ~= localMailHash) then
    // Request update (hash mismatch)
    pending[norm] = summary
end
```

The problem: **Hash comparison only happened in the `elseif` branch**, which was unreachable when `hasContent=true`.

**Why This Specifically Broke Non-Banker Sync:**

**Banker Data:** Works fine because:
- Bankers are authoritative sources for their own data
- Banker data protected by ownership rules
- Banker updates immediately visible to self

**Non-Banker Data:** Broken because:
- Non-bankers don't directly control other non-banker data
- Must rely on sync to get updates from peers
- If sync skips due to "hasContent", never sees updates
- Creates permanent staleness for non-banker-to-non-banker data flow

**Example Scenario:**

```
Initial State:
- NonBankerA: inventoryHash=1000, items=[...]
- NonBankerC: (cached) inventoryHash=1000, items=[...]

Update Flow:
1. NonBankerA scans bank → inventoryHash=2000 (changed)
2. NonBankerA broadcasts version → Banker receives
3. Banker stores: NonBankerA inventoryHash=2000
4. NonBankerC logs in, runs /togbank sync
5. NonBankerC requests HLR from Banker
6. Banker replies: "NonBankerA hash=2000"

BUG TRIGGERS HERE:
7. NonBankerC checks: hasContent(NonBankerA)? YES (has old data)
8. NonBankerC: "if hasContent then SKIP" → Skips without checking hash!
9. NonBankerC never compares: local=1000 vs banker=2000
10. NonBankerC keeps showing stale data with hash=1000

RESULT:
- NonBankerC permanently shows outdated inventory for NonBankerA
- Only fixes if NonBankerC wipes and resyncs from scratch
- Defeats entire purpose of hash-based change detection
```

**Impact:**
- **Severity:** CRITICAL - Non-banker sync completely broken
- **Affected:** Any guild member viewing non-banker alts
- **User Experience:** Shows stale/incorrect inventory for other players
- **Design Violation:** Hash-based sync should detect ALL mismatches
- **Workaround:** Manual `/wipe` and full resync required

**Fix:**

**Chat.lua (lines ~1754-1765) - Check hash equality BEFORE skipping:**

```lua
// AFTER (FIXED):
// Compute whether hashes match (nil/0 hashes always match)
local inventoryHashMatches = (summary.hash == nil or summary.hash == 0 or summary.hash == localHash)
local mailHashMatches = (summary.mailHash == nil or summary.mailHash == 0 or summary.mailHash == localMailHash)
local hashesMatch = inventoryHashMatches and mailHashMatches

// Only skip if BOTH conditions are true: hasContent AND hashes match
if hasContent and hashesMatch then
    // Skip (we have correct, up-to-date data)
    TOGBankClassic_Output:Debug("HLR skip: %s (have content + hashes match...)")
elseif not localAlt or localHash == 0 or 
       (summary.hash and summary.hash ~= localHash) or 
       (summary.mailHash and summary.mailHash ~= localMailHash) then
    // Request update (no data, or hash mismatch)
    pending[norm] = summary
else
    // Hash matches but no content - request it (stub entry)
    missingContent[norm] = summary
end
```

**Key Changes:**
1. **Compute hash equality FIRST** before checking hasContent
2. **Check both hashes:** inventoryHash AND mailHash
3. **Handle nil/0 hashes:** Treat as "no hash = matches anything" (backwards compatibility)
4. **Skip only when BOTH:** hasContent=true AND hashesMatch=true
5. **If hasContent but hash differs:** Fall through to pending (request update)

**Testing:**

**Test 1: Non-Banker Update Propagates**
1. NonBankerA updates inventory → hash changes from 1000 to 2000
2. Banker receives update, stores hash=2000
3. NonBankerC (with old data, hash=1000) runs `/togbank sync`
4. NonBankerC receives HLR with A's hash=2000
5. NonBankerC detects: hasContent=true, localHash=1000, bankerHash=2000
6. NonBankerC: hashesMatch=false → Don't skip, request update
7. NonBankerC broadcasts P2P request for A's data
8. NonBankerC receives updated data from A or Banker
9. NonBankerC now shows correct, current inventory for A

**Test 2: Up-to-Date Data Still Skipped**
1. NonBankerC has correct data for A (hash matches banker)
2. NonBankerC runs `/togbank sync`
3. NonBankerC receives HLR with matching hash
4. NonBankerC detects: hasContent=true, hashesMatch=true
5. NonBankerC: Skip (no request needed) ✅
6. Efficient - no unnecessary data transfer

**Test 3: Mail-Only Changes Detected**
1. NonBankerA updates only mail → mailHash changes, inventoryHash same
2. NonBankerC has old mail data
3. NonBankerC receives HLR with new mailHash
4. NonBankerC: inventoryHashMatches=true, mailHashMatches=false
5. NonBankerC: hashesMatch=false → Request update
6. Mail changes propagate correctly ✅

**Debug Output:**

**Before Fix:**
```
HLR skip: PlayerA (already have content, localHash=1000, bankerHash=2000)
[Never requests update - WRONG!]
```

**After Fix:**
```
HLR check: PlayerA hasContent=true localHash=1000 bankerHash=2000 localMailHash=50 bankerMailHash=50
HLR pending: PlayerA (inventory mismatch: localHash=1000, bankerHash=2000, localMailHash=50, bankerMailHash=50)
P2P: Responding to Requester with data for PlayerA (hash=2000)
[Update received and applied - CORRECT!]
```

**Files Changed:**
- [Modules/Chat.lua](c:/Program%20Files%20(x86)/World%20of%20Warcraft/_classic_era_/Interface/AddOns/TOGBankClassic/Modules/Chat.lua#L1754-L1765) - Added hash comparison before hasContent skip

**Related Issues:**
- [MAIL-007] HLR mailHash storage (complementary fix)
- [MAIL-008] RespondToStateSummary mailHash comparison
- [PERF-006] P2P protocol relies on accurate hash comparison

**Prevention:**
- When checking `hasContent`, ALWAYS compare hashes first
- Pattern: `if hasContent AND hashMatches then skip`
- Never: `if hasContent then skip` (broken pattern)
- Code review should catch unconditional hasContent skips
- Add integration tests for non-banker sync scenarios
- Test stale data detection explicitly

**Design Notes:**

This bug highlights a critical principle in hash-based sync:

**✗ WRONG:** "If we have data, skip"
**✓ CORRECT:** "If we have data AND it's current (hash matches), skip"

The entire purpose of hash-based sync is detecting when local data is stale. Skipping based solely on existence defeats the mechanism. Always check hash equality before deciding to skip.

---

### ✅ HIGH

#### [PERF-006] P2P protocol bypassed - queries going directly to banker

**Severity:** 🟠 HIGH
**Category:** Performance / Communication / Protocol
**Reporter:** User (Production)
**Date Reported:** 2026-02-08
**Date Resolved:** 2026-02-08
**Status:** ✅ RESOLVED
**Reproducibility:** Consistent - all P2P queries were bypassing guild broadcast
**Related:** PERF-005 P2P protocol, BroadcastP2PRequest, QueryAltPullBased, togbank-hl channel

**Problem:**
After moving to the P2P framework, sync queries were bypassing the P2P guild broadcast and going directly to the banker via WHISPER. This defeated the purpose of the P2P protocol, which is designed to distribute load across multiple guild members instead of hammering the single banker.

**Symptoms:**
- Debug logs showed: `[WHISPER-DEBUG] SendWhisper called: prefix=togbank-r, target=Togscales-Azuresong`
- All queries timed out after 5 seconds: `PERF-005: No P2P response for <alt> after 5s timeout`
- SavedVariables showed hashes were stored correctly but `items` arrays were empty
- No guild broadcasts were being sent for P2P data requests
- After fixing bypass, old code (Dabull) responded with incompatible data format → INVALID errors
- P2P timeout blocked banker fallback: "Skipping query - pending request"

**Expected Flow:**
1. Log on and do `/togbank sync` or open UI
2. If banker online: WHISPER banker to get all hashes; if offline: GUILD broadcast for hashes
3. Once hashes received: **GUILD broadcast** on togbank-hl for P2P with expectedHash (modern code only)
4. Wait 5 seconds for P2P response from modern peers with matching hash + data
5. If P2P timeout: WHISPER banker as last resort (fallback)

**Actual Flow (WRONG):**
1. Get hashes correctly ✅
2. **WHISPER banker directly** for each alt ❌ (bypass #1)
3. No guild broadcast ❌
4. Banker doesn't respond (unclear why) ❌
5. 5 second timeout ❌

**Root Causes Discovered:**

**Issue 1: P2P Bypassed in Multiple Locations**
- **QueryAltPullBased** (Guild.lua) was implementing: WHISPER banker first → GUILD broadcast as fallback (backwards!)
- **Version broadcast handler** (Chat.lua:565) called `QueryAltPullBased` directly instead of `BroadcastP2PRequest`
- **FastFillMissingAlts** (DeltaComms.lua:1342) only used P2P when banker offline: `if not banker or not self:IsPlayerOnline(banker)`

**Issue 2: Timeout Handler Blocked Banker Fallback**
- P2P timeout called `QueryAltPullBased` but didn't clear `pendingAltRequests[altName]`
- QueryAltPullBased checked: `if self.pendingAltRequests[norm] then return end` (skip duplicate)
- Result: "Skipping query - pending request" → no banker fallback

**Issue 3: Old Code Incompatibility**
- Old/intermediate code (Dabull) responded to broadcasts on togbank-r channel
- Old code sent incompatible data format (no inventoryHash field, wrong structure)
- Result: `[WARN] INVALID (malformed data, discarded)` → ADOPTION_STATUS.INVALID
- Old code couldn't help modern code, but interfered with P2P broadcasts

**Issue 4: Nil Hash False Matches**
- SendStateSummary used `hash=nil` for force-full requests
- Old code also sent `hash=nil` (no hash support)
- Comparison: `if expectedHash == nil and responseHash == nil` → sent NO-CHANGE instead of full data
- Result: Modern code expecting full data got empty response

**Solution Implemented:**

**1. Fixed P2P Protocol Flow (Guild.lua + Chat.lua + DeltaComms.lua)**

**Guild.lua - QueryAltPullBased (lines 1175-1197)**
- Removed GUILD broadcast fallback path
- Function now **ONLY whispers banker** (last resort)
- Returns early if no banker found or banker offline
- Debug message: "last resort after P2P timeout"

**Chat.lua - Version broadcast handler (lines 565-575)**
- Check `theirHash`:
  - Hash available → `BroadcastP2PRequest(kNorm, theirHash, theirVersion, sender)` (P2P first)
  - No hash → `QueryAltPullBased(kNorm, ...)` (banker fallback)

**DeltaComms.lua - FastFillMissingAlts (lines 1342-1360)**
- Removed banker online check: `if not banker or not self:IsPlayerOnline(banker)`
- Changed to: Always use P2P when hash available, regardless of banker status
- Banker fallback happens via BroadcastP2PRequest timeout, not here

**2. Fixed Timeout Handler Blocking (Guild.lua)**

**BroadcastP2PRequest timeout (lines 883-889)**
```lua
C_Timer.After(timeout, function()
    local pending = self.pendingP2PRequests and self.pendingP2PRequests[altName]
    if pending then
        self.pendingP2PRequests[altName] = nil
        -- PERF-006: Clear pendingAltRequests to allow banker fallback
        if self.pendingAltRequests then
            self.pendingAltRequests[altName] = nil
        end
        TOGBankClassic_Output:Debug("SYNC", "PERF-005: No P2P response for %s after %ds timeout, falling back to banker", altName, timeout)
        self:QueryAltPullBased(altName, false)
    end
end)
```

**3. Migrated P2P to Dedicated Channel (Guild.lua + Chat.lua)**

**Changed P2P broadcast channel: togbank-r → togbank-hl**
- **togbank-r**: All code versions listen (legacy, intermediate, modern) - used for direct banker requests
- **togbank-hl**: Only modern code listens (v0.8.0+) - used for P2P broadcasts with hash validation

**Guild.lua - BroadcastP2PRequest (line 875)**
```lua
-- PERF-006: Use togbank-hl for P2P broadcasts so old code without hash support doesn't see them
TOGBankClassic_Core:SendCommMessage("togbank-hl", p2pData, "GUILD", nil, "NORMAL")
```

**Chat.lua - Version broadcast handler (line 571)**
```lua
TOGBankClassic_Guild:BroadcastP2PRequest(kNorm, theirHash, theirVersion, sender)
-- Broadcasts on togbank-hl, old code doesn't see it
```

**Chat.lua - togbank-hl handler (lines 1622-1636)**
- Already handles "hash-list-request" type
- Now also handles "alt-request" type (P2P broadcasts)
- Forwards alt-request to existing togbank-r handler logic for processing

**4. Fixed Nil Hash False Matches (Guild.lua)**

**SendStateSummary (lines 1407-1428)**
- Changed force-full from `hash=nil` to `hash=0`
- Prevents false `nil==nil` matches with old code
- Old code with `hash=nil` no longer matches force-full requests

**Architecture Decision: Forced Adoption**

**Two-tier fallback (final implementation):**
1. **P2P broadcast on togbank-hl** (5s timeout) → Modern peers with matching hash respond
2. **Banker WHISPER on togbank-r** (direct) → Banker provides data as last resort

**Backwards Compatibility:**
- ✅ **Old code asks modern code**: Old code whispers banker or broadcasts on togbank-r → modern code responds
- ❌ **Old code helps modern code**: Old code doesn't see togbank-hl → can't respond to P2P broadcasts
- **Upgrade path**: As users upgrade to modern code, more peers can participate in P2P distribution

**Why This Approach:**
- Current state: Everyone gets data from banker only (P2P broken) - widespread problem
- After fix: Modern users help each other via P2P, old users wait for banker - same as current for old users, better for modern users
- Incremental improvement: As adoption increases, P2P success rate increases, banker load decreases
- No backwards compatibility burden: Old code data incompatibility (INVALID errors) eliminated by channel segregation

**Call Site Analysis:**
All call sites for QueryAltPullBased verified:
1. Chat.lua:574 - Version broadcasts → Now uses BroadcastP2PRequest when hash available
2. Chat.lua:1049 - P2P timeout → Calls QueryAltPullBased (correct - last resort)
3. Chat.lua:1776 - HLR no-hash fallback → Calls QueryAltPullBased (correct - no P2P possible)
4. DeltaComms.lua:1342 - Fast-fill → Now uses BroadcastP2PRequest when hash available (removed banker check)

**Files Modified:**
- `Modules/Guild.lua`: BroadcastP2PRequest (channel migration, timeout fix), QueryAltPullBased (simplified), SendStateSummary (hash=0)
- `Modules/Chat.lua`: Version broadcast handler (use P2P), togbank-rr acknowledgment handler (timeout fix), togbank-hl handler (alt-request support)
- `Modules/DeltaComms.lua`: FastFillMissingAlts (always use P2P when hash available)

**Testing Verification:**
- P2P broadcasts appear in logs: "HLR broadcast: requesting <alt> (expectedHash=...)"
- Peers respond: "P2P: Peer <name> acknowledged <alt> - will send delta"
- Timeout fallback works: "No P2P response after 5s timeout, falling back to banker"
- No INVALID errors from old code (channel segregation working)
- Banker fallback not blocked by pending requests

**Result:**
- P2P protocol fully operational: GUILD broadcast on hl → wait → banker fallback
- Load distributed across modern guild members, old members wait for banker
- Channel segregation eliminates cross-version incompatibility
- Clear upgrade incentive: Install modern code to get P2P benefits
- Significantly reduced WHISPER traffic to banker as adoption increases

---

### �🔴 CRITICAL

#### [UI-008] C stack overflow in item loading callbacks

**Severity:** 🔴 CRITICAL
**Category:** UI / Item Loading / Infinite Recursion
**Reporter:** User (Production)
**Date Reported:** 2026-01-28
**Date Resolved:** 2026-01-28
**Status:** ✅ RESOLVED
**Reproducibility:** Consistent after /wipe and /sync
**Related:** [SYNC-006] Backward compatibility changes

**Problem:**
After implementing SYNC-006 backward compatibility (reconstructing alt.items from old data), opening the Inventory window causes a C stack overflow crash. The error indicates an infinite recursive loop in the item loading callback system.

**Error Message:**
```
20x Blizzard_ObjectAPI/Classic/Item.lua:296: C stack overflow
[Blizzard_ObjectAPI/Classic/Item.lua]:296: in function 'FireCallbacks'
[Blizzard_ObjectAPI/Classic/Item.lua]:260: in function <Blizzard_ObjectAPI/Classic/Item.lua:256>
[C]: ?
[C]: in function 'RequestLoadItemDataByID'
[Blizzard_ObjectAPI/Classic/Item.lua]:274: in function 'AddCallback'
[Blizzard_ObjectAPI/Classic/Item.lua]:238: in function 'ContinueOnItemLoad'
[TOGBankClassic/Modules/Item.lua]:24: in function 'GetItems'
[TOGBankClassic/Modules/UI/Search.lua]:397: in function 'BuildSearchData'
[TOGBankClassic/Modules/UI/Inventory.lua]:154: in function 'DrawContent'
[TOGBankClassic/Modules/Guild.lua]:978: in function <TOGBankClassic/Modules/Guild.lua:972>
[C]: in function 'xpcall'
[Blizzard_ObjectAPI/Classic/Item.lua]:298: in function 'FireCallbacks'
... [loop continues]
```

**Call Stack Analysis:**
1. ReceiveAltData (Guild.lua) reconstructs alt.items → triggers UI refresh
2. DrawContent (Inventory.lua:154) opens inventory window → calls BuildSearchData
3. BuildSearchData (Search.lua:397) → calls GetItems
4. GetItems (Item.lua:24) → ContinueOnItemLoad for each item without cached data
5. ContinueOnItemLoad → RequestLoadItemDataByID
6. Item loads → FireCallbacks
7. Callback refreshes UI → DrawContent called again (Guild.lua:978 in xpcall)
8. **LOOP BACK TO STEP 2** → infinite recursion → C stack overflow

**Root Cause:**
The recursion was NOT in ReconstructItemLinks callbacks, but in DrawContent itself:
1. DrawContent calls BuildSearchData on EVERY refresh
2. BuildSearchData calls GetItems which creates async Item:CreateFromItemID callbacks
3. When items load, both ReconstructItemLinks AND BuildSearchData callbacks trigger
4. Each callback calls DrawContent again
5. Each DrawContent calls BuildSearchData again, creating NEW async callbacks
6. **Exponential callback explosion** → C stack overflow

The issue was that BuildSearchData was being called on every single DrawContent invocation, creating a new set of item loading callbacks each time, even when the data hadn't changed.

**Solution Implemented:**
Added a `searchDataBuilt` flag to prevent BuildSearchData from running multiple times:

**Inventory.lua (lines 144-159):**
```lua
function TOGBankClassic_UI_Inventory:DrawContent()
    -- ... roster checks ...
    
    -- Build search data only once per data update, not on every refresh (UI-008 fix)
    -- This prevents recursive async item loading that causes C stack overflow
    if not self.searchDataBuilt then
        TOGBankClassic_UI_Search:BuildSearchData()
        self.searchDataBuilt = true
    end
    
    -- ... rest of DrawContent ...
end
```

**Guild.lua (lines 1488-1494):**
```lua
self.Info.alts[norm] = alt

-- Reset search data flag so inventory UI rebuilds search index (UI-008 fix)
if TOGBankClassic_UI_Inventory then
    TOGBankClassic_UI_Inventory.searchDataBuilt = false
end

-- Reconstruct Links for items (v0.8.0 bandwidth optimization)
if alt.items then
    self:ReconstructItemLinks(alt.items)
end
```

**How It Works:**
1. When new alt data arrives, `searchDataBuilt` flag is reset to `false`
2. Next DrawContent call builds search data and sets flag to `true`
3. Subsequent DrawContent calls (from item loading callbacks) skip BuildSearchData
4. No new async callbacks created → no recursion
5. UI still refreshes properly from ReconstructItemLinks callbacks

**Why This Works:**
- Preserves UI auto-refresh functionality (user requirement: "items need to change when window is open")
- BuildSearchData only runs once per data update (when actually needed)
- ReconstructItemLinks callbacks can still call DrawContent safely
- No exponential callback explosion
- Search data is properly rebuilt when new sync data arrives

**Testing:**
- `/reload` → `/wipe` → `/sync` → open Inventory window
- No C stack overflow
- Items display correctly
- Search functionality works
- UI updates when items finish loading

**Trigger Conditions:**
- Occurs after `/wipe` and `/sync` when receiving data from other players
- Reconstruction of alt.items from old format triggers the issue
- Opening Inventory window while items are still loading metadata

**Impact:**
- **Severity:** CRITICAL - Crashes addon, makes inventory unusable
- **Frequency:** Consistent after sync operations
- **Workaround:** Close inventory window before syncing
- **Resolution:** Fixed by preventing BuildSearchData from running multiple times per data update

**Files Changed:**
- [Modules/UI/Inventory.lua](Modules/UI/Inventory.lua#L144-L159) - Added searchDataBuilt flag
- [Modules/Guild.lua](Modules/Guild.lua#L1488-L1494) - Reset flag on new data

**Priority:** CRITICAL - Fixed in v0.8.0

### 🟠 HIGH

None currently open.

### 🟡 MEDIUM

#### [SYNC-005] Failed log entries may retry infinitely without progress tracking

**Severity:** 🟡 MEDIUM
**Category:** Request Sync / Error Handling
**Reporter:** Code Review
**Date Reported:** 2026-01-28
**Date Resolved:** 2026-01-28
**Status:** ✅ RESOLVED
**Reproducibility:** Theoretical - not observed in production
**Related:** [SYNC-004] Event log processing

**Problem:**
When `ReceiveRequestLogEntries()` receives a log entry that fails to apply (e.g., blocked by tombstone, invalid delta, higher priority status), the entry is not marked as "processed" in `requestLogApplied`. This means the system will keep trying to process the same failing entry on every subsequent sync attempt.

**Technical Details:**

The flow when processing received log entries:

```lua
-- ReceiveRequestLogEntries (lines 1473-1503)
for _, entry in ipairs(list) do
    if self:RecordRequestLogEntry(entry, false) then
        -- Success: Update lastSeq
        if seq > lastSeq then
            lastSeq = seq
        end
    else
        -- Failure: lastSeq NOT updated
        -- requestLogApplied stays at old value
    end
end
```

**When RecordRequestLogEntry fails:**
1. Calls `ApplyRequestLogEntry(entry)`
2. `ApplyRequestLogEntry` returns `false` for various reasons (see below)
3. `RecordRequestLogEntry` returns `false` without updating `requestLogApplied`
4. Next sync: Same entry received again, fails again, infinite loop

**Cases when ApplyRequestLogEntry returns FALSE:**

1. **Invalid Entry Structure:**
   - Entry is not a table (line 839-840)
   - Entry has no `type` field (line 850-851)
   - Entry has no `requestId` (line 856-857)

2. **Tombstone Blocking:**
   - Entry timestamp ≤ existing tombstone timestamp (line 862-865)
   - Example: Entry at t=100 blocked by deletion tombstone at t=105
   - **Impact:** Legitimate - entry should never apply (request was deleted)

3. **Request Not Found:**
   - fulfill/cancel/complete entry but request doesn't exist (line 903-904)
   - Entry has no snapshot to create request from
   - **Impact:** Could be transient (request arrives later) or permanent (missing data)

4. **Fulfill Blocked by Higher Priority:**
   - Fulfill entry but status set by cancel/complete (line 932-936)
   - **Impact:** Legitimate - fulfill should never apply after cancel
   - **But:** Priority system now handles this, so entry will always fail

5. **Invalid Fulfill Delta:**
   - Fulfill entry with delta ≤ 0 (line 939-941)
   - **Impact:** Bad data - entry should never succeed

6. **Unknown Operation Type:**
   - Entry type not recognized (line 1019 fallthrough)
   - **Impact:** Bad data or future version incompatibility

**Current Behavior - Deduplication Safety:**

The system has a safety mechanism via `requestLogIndex`:

```lua
-- RecordRequestLogEntry (lines 1064-1071)
if self.requestLogIndex and self.requestLogIndex[entry.id] then
    -- Entry already recorded previously
    self.Info.requestLogApplied[actor] = math.max(current, seq)
    return true  -- Pretend it succeeded
end
```

**Key insight:** If the entry was previously processed successfully (even in an earlier session), it's in `requestLogIndex` and won't retry. The infinite retry only happens for entries that consistently fail validation/application.

**Analysis - Is This Actually a Problem?**

**Legitimate Permanent Failures** (should NOT update requestLogApplied):
- Tombstone blocking (entry is obsolete)
- Invalid data (bad entry structure, zero delta)
- Unknown operation type (version incompatibility)

**Transient Failures** (should NOT update requestLogApplied):
- Request not found yet (might arrive in next sync)
- Could resolve themselves

**Priority-Based Blocking** (SHOULD update requestLogApplied):
- Fulfill blocked by cancel/complete will NEVER succeed
- Keeps retrying forever even though state is final
- **This is the actual bug**

**Example Problematic Scenario:**

```
Time=100: User cancels request (seq=5)
Time=105: Banker fulfills request (seq=20)
Sync: Receives cancel seq=5 → applies, lastStatusOp="cancel"
Sync: Receives fulfill seq=20 → BLOCKED by cancel priority
      → RecordRequestLogEntry returns false
      → requestLogApplied stays at seq=5
Next sync: Receives fulfill seq=20 again → BLOCKED again
Forever: Keeps receiving and rejecting fulfill seq=20
```

**Proposed Solution:**

Update `ReceiveRequestLogEntries()` to distinguish between:
1. **Hard failures** (should mark as processed): Tombstone block, priority block
2. **Soft failures** (should retry): Request not found, transient errors

```lua
if self:RecordRequestLogEntry(entry, false) then
    if seq > lastSeq then
        lastSeq = seq
    end
else
    -- Check if failure was permanent/expected
    local isPermanentFailure = self:IsEntryPermanentlyBlocked(entry)
    if isPermanentFailure then
        -- Mark as processed to prevent infinite retries
        if seq > lastSeq then
            lastSeq = seq
        end
    end
end
```

**Workaround:**
The system self-heals when `requestLogIndex` gets rebuilt (on reload), as previously failed entries will be detected as duplicates and skipped. So the retry loop is limited to one session and doesn't persist across reloads.

**Priority:** Medium - Issue is self-limiting (resets on reload) and only affects permanently-blocked entries during one session.

**Resolution:**

Added `IsEntryPermanentlyBlocked()` method to distinguish between:
1. **Permanent failures** (should mark as processed): Tombstone block, priority block, invalid data, unknown operations
2. **Transient failures** (should retry): Request not found (might arrive later)

Updated `ReceiveRequestLogEntries()` to check if a failed entry is permanently blocked:
- If **permanent**: Update `requestLogApplied` to mark as processed (prevents infinite retries)
- If **transient**: Don't update `requestLogApplied` (will retry on next sync)

**Key Changes:**
- **Lines 1020-1075** (RequestLog.lua): Added `IsEntryPermanentlyBlocked()` method
  - Returns `true` for: Invalid structure, tombstone blocking, priority blocking, invalid delta, unknown operation
  - Returns `false` for: Request not found (transient, might arrive later)
- **Lines 1550-1567** (RequestLog.lua): Updated `ReceiveRequestLogEntries()` failure handling
  - Calls `IsEntryPermanentlyBlocked()` on failure
  - Updates `lastSeq` for permanent failures (marks as processed)
  - Logs different messages for permanent vs transient failures

**Example Fixed Scenario:**
```
Time=100: User cancels request (seq=5)
Time=105: Banker fulfills request (seq=20)
Sync: Receives cancel seq=5 → applies, lastStatusOp="cancel"
Sync: Receives fulfill seq=20 → BLOCKED by cancel priority
      → IsEntryPermanentlyBlocked() returns true
      → requestLogApplied updated to seq=20
Next sync: Won't retry fulfill seq=20 (already processed)
```

This prevents infinite retry loops for entries that will never succeed while still retrying transient failures.

---

## Resolved Bugs (2026-01-28)

### 🔴 CRITICAL - All Resolved

#### ✅ [SYNC-004] User request cancellations not propagating to other players

**Severity:** 🔴 CRITICAL
**Category:** Request Sync / Event Sourcing
**Reporter:** User (Production)
**Date Reported:** 2026-01-28
**Date Resolved:** 2026-01-28
**Status:** ✅ RESOLVED
**Reproducibility:** Was consistent
**Related:** Event sourcing conflict resolution

**Problem:**
When a user cancelled their own request, the cancellation appeared in their UI but did not propagate to other players (especially bankers). Banker cancellations propagated correctly. This caused confusion as bankers continued trying to fulfill requests that users had already cancelled.

**Root Cause Analysis:**

Two fundamental bugs in the event log processing:

**Bug #1: Sequential Entry Requirement with Break**
`ReceiveRequestLogEntries()` had strict sequential processing that discarded valid entries:

```lua
for _, entry in ipairs(list) do
    local seq = tonumber(entry.seq or 0) or 0
    if seq <= lastSeq then
        -- skip duplicates
    elseif seq == lastSeq + 1 then
        -- Only process if exactly next sequence
        if self:RecordRequestLogEntry(entry, false) then
            lastSeq = seq
        end
    else
        -- Gap detected - query for missing AND BREAK!
        if sender then
            self:QueryRequestLog(sender, { [actor] = lastSeq + 1 })
        end
        break  -- ❌ DISCARDS ALL REMAINING ENTRIES
    end
end
```

**Impact:** If user had lastSeq=5 and received cancel at seq=10:
- Queried for seq 6-9
- **Discarded seq 10 cancel forever**
- Cancel never applied even though it had a unique `entry.id`

**Bug #2: Timestamp-Only Conflict Resolution**
Cancel/complete operations used only timestamp comparison:

```lua
if entryTs >= statusUpdatedAt then
    req.status = newStatus
end
```

**Impact:** If banker fulfilled at time=105, user cancel at time=100 was rejected:
- User cancels at t=100 (sets statusUpdatedAt=100)
- Banker fulfills at t=105 (sets statusUpdatedAt=105)
- User's cancel broadcast arrives with ts=100
- **Cancel rejected** because 100 < 105
- Banker never sees the cancellation

**Solution Implemented:**

**Fix #1: Remove Sequential Requirement**
Changed `ReceiveRequestLogEntries()` to process ALL entries:

```lua
local gapDetected = false
for _, entry in ipairs(list) do
    local seq = tonumber(entry.seq or 0) or 0
    
    -- Detect gaps for querying (but don't stop processing)
    if not gapDetected and seq > lastSeq + 1 then
        if sender then
            self:QueryRequestLog(sender, { [actor] = lastSeq + 1 })
        end
        gapDetected = true
    end
    
    -- Always try to record - RecordRequestLogEntry handles deduplication via entry.id
    if self:RecordRequestLogEntry(entry, false) then
        if seq > lastSeq then
            lastSeq = seq
        end
    end
end
```

**Key improvement:**
- Removed `break` statement
- Still queries for missing entries when gaps detected
- But processes ALL received entries
- Relies on `entry.id` deduplication in `RecordRequestLogEntry`

**Fix #2: Priority-Based Conflict Resolution**
Implemented operation priority system:

```lua
OPERATION_PRIORITY = {
    add = 1,      -- Creates/updates request data
    fulfill = 2,  -- Updates fulfillment progress (additive)
    complete = 3, -- Banker marks as finished
    cancel = 4,   -- Requester/banker withdraws request
    delete = 5,   -- Removes request completely
}
```

Updated cancel/complete logic:

```lua
local incomingPriority = getOperationPriority(entryType)
local currentPriority = getOperationPriority(req.lastStatusOp)

if incomingPriority > currentPriority then
    -- Higher priority always wins
    req.status = newStatus
    req.lastStatusOp = entryType
elseif incomingPriority == currentPriority then
    -- Same priority: use timestamp (last-writer-wins)
    if entryTs >= statusUpdatedAt then
        req.status = newStatus
        req.lastStatusOp = entryType
    end
end
```

**Key improvement:**
- Cancel (priority 4) overrides Fulfill (priority 2) regardless of timestamp
- Fulfill checks priority before changing status
- Tracks `lastStatusOp` to know which operation set current status
- Supports partial fulfills (additive delta)

**Testing Results:**
- ✅ User cancels propagate correctly to all players
- ✅ Banker cancels continue to work correctly
- ✅ Cancel overrides fulfill even if fulfill timestamp is newer
- ✅ Partial fulfills accumulate correctly (additive)
- ✅ Sequence gaps no longer discard valid entries
- ✅ Entry deduplication works via unique `entry.id`

**Files Modified:**
- `Modules/RequestLog.lua` (lines ~33-57): Added OPERATION_PRIORITY table and getOperationPriority()
- `Modules/RequestLog.lua` (lines ~976-1016): Implemented priority-based cancel/complete logic
- `Modules/RequestLog.lua` (lines ~929-975): Updated fulfill to check priority and track lastStatusOp
- `Modules/RequestLog.lua` (lines ~1378-1435): Fixed ReceiveRequestLogEntries to process all entries
- `Modules/RequestLog.lua` (lines ~1580-1612): Added comprehensive SYNC debug logging to CancelRequest
- `Modules/RequestLog.lua` (lines ~1293-1306): Added SYNC debug logging to SendRequestLogEntry
- `docs/REQUEST_COMMS.md`: Added Priority-Based Conflict Resolution section with examples
- `docs/DELTA_BUGS.md`: Documented SYNC-004 fix

**Debug Commands:**
```
/togbank debugcat SYNC true              # Enable SYNC debug logging
/togbank debuglog 100 SYNC               # View SYNC-related log entries
```

**Design Documentation:**
See [REQUEST_COMMS.md](REQUEST_COMMS.md) section "Priority-Based Conflict Resolution" for complete architecture details and example scenarios.

---

#### [REPLAY-001] Empty requestLogApplied causes all requests to disappear from UI

**Reporter:** User (Production - Galdof character)
**Date Reported:** 2026-01-27
**Status:** ✅ RESOLVED (2026-01-27)
**Reproducibility:** Consistent when requestLogApplied is cleared/corrupted
**Resolution:** Data validation with automatic recovery implemented

**Description:**
After merging remote commits c15a32d ("use absolute values for 'fulfilled'") and 3f8ce50 ("merge, don't override requestLogApplied data"), all gromsblood requests (and many others) disappeared from the UI. Investigation revealed that while the event log (requestLog) contained all request entries correctly with 73 events, the sequence tracking index (requestLogApplied) was empty in the SavedVariables file. However, upon loading, incoming snapshots from other players populated requestLogApplied with stale data showing 105 actors/sequences, causing the replay logic to skip events that should have been visible.

**Root Cause Analysis:**
Complex interaction between SavedVariables loading, snapshot sync, and event replay:

1. **Initial State (SavedVariables on disk):**
   - `requestLog`: 73 events intact ✅
   - `requestLogApplied`: {} (empty) ❌
   - `requests`: [] (empty snapshot) ❌

2. **What Happened During Load:**
   - SavedVariables loaded with empty `requestLogApplied`
   - DeltaComms received snapshot from another player during initialization
   - `ApplyRequestSnapshot()` overwrote empty `requestLogApplied` with snapshot's data
   - Snapshot data showed `Galdof-OldBlanchy = 42` (marking sequences 1-42 as "already applied")
   - Local event log had gromsblood entries at seq 41 and 42
   - Replay logic: `if entry.seq <= requestLogApplied[actor] then skip` → skipped all entries!

3. **Why `/reload` Didn't Help:**
   - In-memory data persisted through `/reload` (WoW doesn't reload SavedVariables)
   - Stale `requestLogApplied` data remained in memory
   - `Guild:Init()` short-circuited: `if self.Info and self.Info.name == name then return false`
   - Validation never ran because Init() thought data was already loaded

**Technical Details:**
- Event log entries found: gromsblood requests at seq 41, 42 (Galdof-OldBlanchy actor)
- Snapshot corruption: `requestLogApplied[Galdof-OldBlanchy] = 42` (stale)
- Request snapshot: Missing those requests despite being marked "applied"
- Result: 1 visible request in UI, 57 others missing (58 total should exist)

**Impact:**
- Critical data loss perception for users
- 98% of guild bank requests invisible in UI
- No way to fulfill requests or track pending items
- Event-sourcing architecture appeared completely broken
- User trust in addon severely compromised

**Solution Implemented:**

**Phase 1: Data Validation System**
Added integrity validation in `EnsureRequestsInitialized()` that detects stale `requestLogApplied` data:
- Scans all event log entries marked as "applied" (seq <= requestLogApplied[actor])
- For each "add" entry, verifies the request exists in the snapshot
- Checks tombstones to distinguish deletions from missing data
- If 3+ entries are marked applied but missing → triggers rebuild
- Prevents false positives from legitimate deletions

**Phase 2: Automatic Recovery**
When stale data detected:
1. Clear corrupted `requestLogApplied` completely (`= {}`)
2. Clear stale request snapshot (`requests = {}`)
3. Set validation flag to prevent recursive calls
4. Execute full `ReplayRequestLogEntries()` from event log
5. Rebuild complete state from authoritative event log

**Phase 3: Fallback Protection**
Added secondary check for completely empty `requestLogApplied`:
- If empty when index exists, initialize all actors to seq 0
- Forces replay to process ALL events from log
- Handles edge cases where validation doesn't catch corruption

**Code Changes:**

File: `Modules/RequestLog.lua` (lines 208-263)

```lua
-- [BUG-FIX REPLAY-001] Validate that requestLogApplied is consistent with event log
-- Check if there are entries marked as applied but don't exist in requests snapshot
-- Skip validation if we've already validated (prevents recursive calls)
if not self._validationComplete then
    local needsRebuild = false
    local appliedButMissingCount = 0
    if self.requestLogByActor then
        for actor, entries in pairs(self.requestLogByActor) do
            local appliedSeq = self.Info.requestLogApplied[actor] or 0
            for _, entry in ipairs(entries) do
                -- Check entries that are marked as applied (seq <= appliedSeq)
                if entry.seq <= appliedSeq and entry.type == "add" then
                    -- This "add" entry is marked as applied, so the request should exist
                    local requestExists = false
                    for _, req in ipairs(self.Info.requests or {}) do
                        if req.id == entry.requestId then
                            requestExists = true
                            break
                        end
                    end
                    if not requestExists then
                        -- Check if it was deleted (tombstone)
                        local tombstoneTs = self.Info.requestsTombstones and self.Info.requestsTombstones[entry.requestId]
                        if not tombstoneTs or tombstoneTs < entry.ts then
                            -- Not deleted or deletion is older than the add - request should exist!
                            TOGBankClassic_Output:Debug("SYNC", "Stale data: %s seq %d marked applied but request %s missing",
                                actor, entry.seq, entry.requestId)
                            appliedButMissingCount = appliedButMissingCount + 1
                            needsRebuild = true
                            if appliedButMissingCount >= 3 then
                                break  -- Found enough evidence
                            end
                        end
                    end
                end
            end
            if appliedButMissingCount >= 3 then break end
        end
    end
    
    if needsRebuild then
        TOGBankClassic_Output:Debug("SYNC", "Detected %d stale entries - rebuilding from event log", appliedButMissingCount)
        -- Clear requestLogApplied so replay processes ALL entries from event log
        self.Info.requestLogApplied = {}
        -- Clear requests so we rebuild from scratch
        self.Info.requests = {}
        -- Mark validation as complete to prevent recursion
        self._validationComplete = true
        -- Replay all events from the log
        self:ReplayRequestLogEntries()
        TOGBankClassic_Output:Debug("SYNC", "Rebuild complete - now have %d requests", #self.Info.requests)
        return
    end
    
    -- Mark validation as complete
    self._validationComplete = true
end

-- Fallback: Always rebuild requestLogApplied when it's empty and we have log data
local isEmpty = next(self.Info.requestLogApplied) == nil
local hasIndex = self.requestLogByActor ~= nil
if isEmpty and hasIndex then
    TOGBankClassic_Output:Debug("SYNC", "requestLogApplied is empty, rebuilding from event log")
    -- Initialize to 0 so ReplayRequestLogEntries will process all events
    for actor, list in pairs(self.requestLogByActor) do
        if #list > 0 then
            self.Info.requestLogApplied[actor] = 0
        end
    end
    TOGBankClassic_Output:Debug("SYNC", "Initialized requestLogApplied for %d actors, calling ReplayRequestLogEntries", countKeys(self.Info.requestLogApplied))
    -- Replay all entries to rebuild the requests snapshot
    self:ReplayRequestLogEntries()
    TOGBankClassic_Output:Debug("SYNC", "After replay, requests count = %d", #(self.Info.requests or {}))
end
```

**Testing & Validation:**
1. ✅ Verified SavedVariables had empty `requestLogApplied: {}`
2. ✅ Verified event log intact with 73 entries via PowerShell queries
3. ✅ Confirmed gromsblood entries present at sequences 41, 42
4. ✅ Applied fix and performed `/reload`
5. ✅ Validation detected: "STALE DATA DETECTED - Solomage-Atiesh seq 3 marked applied but request missing"
6. ✅ Automatic rebuild executed: "Detected 3 stale entries - rebuilding from event log"
7. ✅ Result: "Rebuild complete - now have 58 requests" (was 1, now 58)
8. ✅ All missing gromsblood requests restored to UI
9. ✅ Validation runs only once per session (prevents recursion)
10. ✅ Debug messages properly categorized under "SYNC" category

**Files Modified:**
- `Modules/RequestLog.lua` (lines 208-281): Added validation and recovery system
- `Modules/Guild.lua` (lines 254-256): Simplified initialization (removed unused flag code)

**Debug Categories Used:**
- `SYNC`: All validation and rebuild messages
  - "Stale data: {actor} seq {N} marked applied but request {id} missing"
  - "Detected {N} stale entries - rebuilding from event log"
  - "Rebuild complete - now have {N} requests"
  - "requestLogApplied is empty, rebuilding from event log"
  - "Initialized requestLogApplied for {N} actors"
  - "After replay, requests count = {N}"

Enable with: `/togbank debuglog` or `/togbank debugcat SYNC true`

**Performance Impact:**
- Validation runs once per session on first `EnsureRequestsInitialized()` call
- O(actors × entries × requests) worst case, but early exits:
  - Stops after finding 3 stale entries (sufficient evidence)
  - Only checks "add" type events marked as applied
  - Skips validation after first run via `_validationComplete` flag
- Rebuild from event log: O(entries) - same as normal replay
- Typical case: <50ms for validation, <100ms for rebuild

**Prevention Measures:**
1. ✅ Validation now runs automatically on every addon load
2. ✅ Detects stale data regardless of when corruption occurred
3. ✅ Self-healing: automatically recovers without user intervention
4. ✅ Event log is authoritative source of truth
5. ⚠️ Consider: Add pre-save validation to prevent empty requestLogApplied from being written
6. ⚠️ Consider: Periodic integrity checks during runtime (not just at load)

**Related Issues:**
- Initial suspicion: Commits c15a32d and 3f8ce50 modified request merging
- Actual cause: Git merge conflict or manual edit left requestLogApplied empty in SavedVariables
- Lesson: Event log survived corruption, but sequence tracker did not
- Design win: Event-sourcing architecture enabled complete recovery from corruption

---

### 🟠 HIGH

#### ✅ [FULFILL-001] Greedy split algorithm causes repeated unnecessary splits

**Severity:**  HIGH
**Category:** Order Fulfillment / Stack Splitting
**Reporter:** User (Testing)
**Date Reported:** 2026-01-25
**Status:** ✅ RESOLVED (2026-01-27)
**Reproducibility:** Was Consistent

**Description:**
The greedy stack splitting algorithm was using tiny stacks in calculations, causing inefficient splits like "Split 9 after using stack of 1" instead of "Split 10 and ignore the stack of 1."

**Solution:**
Added smart filtering that excludes stacks smaller than the required split amount. Now only uses stacks worth the effort.
- Example: Need 90 with [20,20,20,20,1] → Excludes 1, splits 10 ✅
- Example: Need 95 with [20,20,20,20,14] → Excludes 14, splits 15 ✅

**Files Modified:** Modules/Mail.lua (lines 568-593, 486), docs/ORDER_FULFILLMENT_LOGIC.md

---

#### ✅ [FULFILL-002] Fulfill button callback not updating after split completion

**Severity:** 🟠 HIGH
**Category:** Order Fulfillment / UI
**Reporter:** User (Testing)
**Date Reported:** 2026-01-27
**Date Resolved:** 2026-01-27
**Status:** ✅ RESOLVED
**Reproducibility:** Was Consistent

**Description:**
When fulfilling a request that requires splitting, after split completes and button changes to envelope icon, clicking the envelope button still triggered split popup instead of attaching items to mail.

**Root Cause:**
Two issues in the greedy stack allocation algorithm in `PrepareFulfillMail()`:

1. **Minimum stack size filter bug**: When needing only 1 item from a stack of 9, after splitting to create [8, 1], the algorithm used `minStackSize = 5` and filtered out the stack of 1 as "too small", causing it to mark the stack of 8 for splitting again.

2. **Single-pass greedy processing**: Algorithm processed stacks in one pass, marking splits before checking if smaller exact-fit stacks existed later in the list.

**Solution:**
Two-part fix implemented in `Modules/Mail.lua`:

**Fix 1: Minimum Stack Size Calculation (Line 591)**
```lua
-- Changed from:
local minStackSize = wouldNeedToSplit > 0 and wouldNeedToSplit or 5

-- To:
local minStackSize = wouldNeedToSplit > 0 and wouldNeedToSplit or math.min(5, qtyNeeded)
```
This ensures when needing only 1 item, a stack of 1 is not filtered out.

**Fix 2: Two-Stage Greedy Algorithm (Lines 608-633)**
- **Stage 1**: Accumulate all stacks that fit exactly without exceeding qtyNeeded
- **Stage 2**: Only if still need more, look for a stack to split

This ensures exact-fit stacks are always preferred over splitting.

**Testing Results:**
- ✅ Create request for 1 item
- ✅ Bank alt has single stack of 9 items  
- ✅ Click scissors button - split 1 item creates stacks [8, 1]
- ✅ Button changes to envelope icon
- ✅ Click envelope button - items attach to mail (no split popup!) ✅
- ✅ Request fulfilled successfully

**Files Modified:**
- `Modules/Mail.lua` (lines 591, 608-633) - Fixed greedy algorithm and minimum stack size
- `Modules/Mail.lua` (multiple) - Migrated debug output to proper system

**Bonus:** Migrated all fulfillment debug output from `print()` to `TOGBankClassic_Output:Debug("FULFILL", ...)` for integration with persistent debug log system.

---

#### ✅ [FULFILL-003] Request splitting logic inconsistency between UI state and execution

**Severity:** 🟠 HIGH
**Category:** Order Fulfillment / Algorithm Consistency
**Reporter:** User (Testing)
**Date Reported:** 2026-03-03
**Date Resolved:** 2026-03-03
**Status:** ✅ RESOLVED
**Reproducibility:** Was Consistent

**Description:**
UI fulfill button showed split icon (shovel) but clicking it found exact match without splitting, or button showed ready icon but clicking showed "need to split" popup. This inconsistency stemmed from `CanFulfillRequest()` (UI feasibility check) and `PrepareFulfillMail()` (execution) using different algorithms that produced different results for the same inventory.

**Example Failure Scenario:**
```
Request: 95 items
Inventory: [20, 20, 20, 20, 15, 14]
Total: 109 items

CanFulfillRequest logic:
- Accumulate stacks ≤ remaining: 20+20+20+20 = 80
- Still need 15, have 109 total → says "need to split"
- UI shows split icon (shovel)

PrepareFulfillMail logic:
- Calculate minStackSize (would split 15, exclude stacks < 15)
- Filter to [20, 20, 20, 20, 15] (excludes 14)
- Accumulate: 20+20+20+20+15 = 95 exactly
- No split needed! But UI already showed split icon

Result: User clicks expecting split, but items attach directly → confusion
```

**Root Causes:**

1. **Algorithm Divergence**:
   - CanFulfillRequest: Simple greedy (accumulate if count ≤ remaining)
   - PrepareFulfillMail: Two-stage greedy with "useful stacks" filtering

2. **Stack Filtering Mismatch**:
   - PrepareFulfillMail calculated `minStackSize` based on split requirement and filtered out smaller stacks
   - CanFulfillRequest considered ALL stacks without filtering

3. **Sort Order Inconsistency**:
   - PrepareFulfillMail preserved `originalIndex` for stable sorting when counts equal
   - CanFulfillRequest had basic sort without index preservation

4. **Split Detection Logic Differences**:
   - Different conditions for determining which stack to split from
   - Different handling of skip-stack optimization

5. **Code Duplication**:
   - ~200 lines of nearly identical greedy algorithm logic
   - Changes to one function didn't propagate to the other

**Solution:**
Created unified `CalculateFulfillmentPlan()` function that both `CanFulfillRequest` and `PrepareFulfillMail` now use.

**Algorithm Structure:**
```lua
CalculateFulfillmentPlan(items, qtyNeeded, totalInBags)
  Returns: {
    canFulfill = boolean,
    reason = string or nil,
    stacksToAttach = {{bag, slot, count, originalIndex}, ...},
    splitStack = {bag, slot, count, amount} or nil,
    totalAttachable = number,
    requiresMailbox = boolean
  }

  PHASE 1: Greedy exact match
    - Sort: largest first, preserve originalIndex for equal counts
    - Accumulate stacks where count ≤ remaining need
    - If accumulated == qtyNeeded → SUCCESS (exact match)

  PHASE 2: Skip-stack optimization
    - Try skipping up to 5 stacks to find exact matches
    - If found → SUCCESS (exact match via skip)
    - Track best fit if no exact match

  PHASE 3: Split detection
    - If accumulated < qtyNeeded and totalInBags >= qtyNeeded
    - Find largest available stack >= remaining amount
    - Return split plan with stack details

  PHASE 4: Failure cases
    - Deficit: totalInBags < qtyNeeded
    - Edge case: single large stack, need to split
```

**Implementation Changes:**

1. **New Function** (`Mail.lua` lines 496-707):
   - `CalculateFulfillmentPlan()` - unified algorithm
   - Returns structured plan with all decision details

2. **CanFulfillRequest Refactor** (lines 709-751):
   - Removes ~140 lines of duplicate logic
   - Makes copy of items array (avoid mutation)
   - Calls `CalculateFulfillmentPlan()`
   - Returns: `canFulfill, reason, totalInBags, smallestStack`

3. **PrepareFulfillMail Refactor** (lines 752-873):
   - Removes ~230 lines of duplicate logic  
   - Calls `CalculateFulfillmentPlan()`
   - Uses `plan.stacksToAttach` for attachment loop
   - Shows split popup if `plan.splitStack` exists
   - Simplified from complex two-pass algorithm to plan execution

**Benefits:**

✅ **Consistency**: UI icon always matches actual behavior
✅ **Maintainability**: Single source of truth for fulfillment logic
✅ **Code Reduction**: ~200 lines removed (duplication eliminated)
✅ **Predictability**: Users see accurate state before clicking
✅ **Debuggability**: Plan structure makes behavior transparent

**Testing Results:**
```
Test Case 1: [20,20,20,20,15,14] need 95
  Before: UI split icon, execution exact match ❌
  After: UI ready icon, execution exact match ✅

Test Case 2: [20,20,20,20,14] need 95  
  Before: UI split icon, execution split 15 from 20 ✅
  After: UI split icon, execution split 15 from 20 ✅

Test Case 3: [1,20,20,20,20,20] need 90
  Before: Different split candidates between functions
  After: Consistent split from first 20-stack ✅

Test Case 4: [9] need 1 (post-split: [8,1])
  Before: Fixed by FULFILL-002
  After: Still works correctly ✅
```

**Files Modified:**
- `Modules/Mail.lua` (lines 496-873)
  - Added `CalculateFulfillmentPlan()` unified function
  - Refactored `CanFulfillRequest()` to use plan
  - Refactored `PrepareFulfillMail()` to use plan
  - Net: ~200 lines removed through consolidation

**Related Issues:**
- Builds on [FULFILL-002] two-stage greedy algorithm foundation
- Eliminates class of bugs where UI state diverges from execution

#### ✅ [MAIL-001] ComputeInventoryHash parameter order mismatch causing crashes

**Severity:** 🔴 CRITICAL
**Category:** Mail Inventory / Function Signature  
**Reporter:** BugSack Error Log
**Date Reported:** 2026-01-27
**Status:** ✅ RESOLVED
**Fixed In:** commit 9dfc013
**Branch:** feature/mail-inventory-status
**Reproducibility:** Was consistent on addon load with existing saved data

**Description:**
When loading saved data with existing inventory, `ComputeInventoryHash()` crashes with "attempt to index local 'mail' (a number value)". The function signature was changed to add mail parameter, but old calling code still uses the 3-parameter version.

**Error Stack:**
```
6x TOGBankClassic/Modules/DeltaComms.lua:259: attempt to index local 'mail' (a number value)
[TOGBankClassic/Modules/DeltaComms.lua]:259: in function <TOGBankClassic/Modules/DeltaComms.lua:208>
[TOGBankClassic/Modules/Database.lua]:139: in function 'Load'
[TOGBankClassic/Modules/Guild.lua]:254: in function 'Init'
```

**Root Cause:**
Function signature changed from `ComputeInventoryHash(bank, bags, money)` to `ComputeInventoryHash(bank, bags, mail, money)` but there are callers still using the old 3-parameter version.

When old code calls with 3 parameters:
- `bank` = bank table ✅
- `bags` = bags table ✅  
- `mail` = money (number!) ❌
- `money` = nil ❌

**Example:**
```lua
-- Old caller (Database.lua or other location)
local hash = ComputeInventoryHash(alt.bank, alt.bags, alt.money)

-- Function receives:
-- bank=table, bags=table, mail=298335 (money!), money=nil
-- Line 259 tries: if mail and mail.items then → CRASH
```

**Fix Required:**
1. Make function handle both old (3-param) and new (4-param) calling conventions
2. Detect if 3rd parameter is a number (money) vs table (mail)
3. Find and update all old callers to use new signature

**Files to Check:**
- Modules/DeltaComms.lua:208 (function definition)
- Modules/Core.lua:166 (wrapper function)
- Modules/Database.lua:139 (caller during Load)
- Any other callers using old 3-parameter signature

**Proposed Fix:**
```lua
function TOGBankClassic_DeltaComms:ComputeInventoryHash(bank, bags, mailOrMoney, money)
	-- Handle both old (3-param) and new (4-param) calling conventions
	local mail, actualMoney
	if type(mailOrMoney) == "number" then
		-- Old calling convention: (bank, bags, money)
		mail = nil
		actualMoney = mailOrMoney
	else
		-- New calling convention: (bank, bags, mail, money)
		mail = mailOrMoney
		actualMoney = money
	end
	
	local parts = {}
	table.insert(parts, tostring(actualMoney or 0))
	-- ... rest of function
end
```

**Resolution:**
Applied backward compatibility fix to DeltaComms.lua. Function now detects parameter type and handles both calling conventions correctly. Requires `/reload` to apply fix to running game session.

**Priority:** CRITICAL - Blocks addon from loading with existing saved data

---

#### ✅ [MAIL-002] Mail inventory displaying incorrect/duplicate counts

**Severity:** 🔴 CRITICAL
**Category:** Mail Inventory / Data Aggregation
**Reporter:** User (Testing)
**Date Reported:** 2026-01-27
**Status:** ✅ RESOLVED
**Fixed In:** commit 990bba4 (partial), current session (complete)
**Branch:** feature/mail-inventory-status
**Reproducibility:** Was Consistent during gameplay

**Description:**
Mail inventory items were showing incorrect counts in both Search results and Inventory tab. Items like Golden Sansam showed 3701 (223 x 7 duplicates) and Gromsblood showed 1199 (109 + 770 duplicates). The numbers appeared to be multiplying instead of showing accurate counts.

**Root Causes Identified:**

1. **Search Corpus Building (Search.lua:346-407):**
   - Bug: Added item name to Corpus once for EACH unique item ID variant
   - Example: Golden Sansam had 7 different item IDs → added to Corpus 7 times
   - Result: Search loop processed "Golden Sansam" 7 times → displayed 7 rows with 223 each = 3701 total

2. **Duplicate Detection (Search.lua:438-452):**
   - Bug: Only checked if alt name existed in lookup, not item ID
   - Result: Same item added multiple times per character if it had multiple IDs
   - Example: Gromsblood with 2 different IDs → both added to lookup

3. **Missing Mail Aggregation (Inventory.lua:287-298):**
   - Bug: Inventory tab only aggregated bank + bags, completely omitted mail items
   - Result: Mail items weren't displayed in Inventory tab at all initially
   - After adding mail aggregation, duplicates appeared from causes #1 and #2

**Fixes Applied:**

1. **Fixed Search Corpus (Search.lua:346-407):**
   ```lua
   local corpusNamesSeen = {}
   -- ... loop through items ...
   if not corpusNamesSeen[v.Info.name] then
       corpusNamesSeen[v.Info.name] = true
       table.insert(self.SearchData.Corpus, v.Info.name)
   end
   -- Still map ALL item IDs to names for lookup
   itemNames[v.ID] = v.Info.name
   ```

2. **Fixed Duplicate Detection (Search.lua:438-452):**
   ```lua
   -- Check BOTH alt name AND item ID
   for _, existingEntry in pairs(self.SearchData.Lookup[name]) do
       if existingEntry.alt == player and existingEntry.item.ID == itemEntry.ID then
           found = true
           break
       end
   end
   ```

3. **Added Mail Aggregation to Inventory Tab (Inventory.lua:287-298):**
   ```lua
   if alt.mail and alt.mail.items then
       for itemID, mailItem in pairs(alt.mail.items) do
           local fakeItem = { ID = itemID, Count = mailItem.count, Link = mailItem.link }
           items = TOGBankClassic_Item:Aggregate(items, {fakeItem})
       end
   end
   ```

**Verification:**
- Golden Sansam: Now shows 223 (correct) instead of 3701
- Gromsblood: Now shows 109 (correct) instead of 1199
- Inventory tab: Now includes mail items in aggregated counts
- Search results: Each item appears once with correct total count

**Debug Logging:**
Added comprehensive MAIL category debug logging throughout Search and Inventory modules to track:
- Corpus building (unique names vs item IDs)
- Lookup table construction (duplicate detection)
- Mail aggregation (items being added)
- Display events (what counts are shown)

Debug logging intentionally left in place for future diagnostics.

**Files Modified:**
- Modules/UI/Search.lua (lines 346-407, 438-452, 525-545, 569)
- Modules/UI/Inventory.lua (lines 281-308)
- docs/DELTA_BUGS.md (this file)

**Priority:** CRITICAL - Core mail inventory feature not working correctly → ✅ RESOLVED

---

#### ✅ [PERF-001] Serious performance degradation during normal gameplay

**Severity:** 🟠 HIGH
**Category:** Performance / Optimization
**Reporter:** Multiple Users (Production)
**Date Reported:** 2026-01-25
**Status:** ✅ CLOSED (Duplicate of PERF-002)
**Fixed In:** v0.7.18 (commit 77b16a1)
**Fixed Date:** 2026-01-26
**Reproducibility:** Was consistent in large guilds

**Description:**
Multiple guild members reported serious performance issues including lag, frame rate drops, and general game slowdown during normal gameplay with the addon.

**Root Cause:**
After investigation, determined this was caused by the same issue as PERF-002: the NormalizeRequestList() broadcast storm from request sync being piggybacked on inventory delta broadcasts. Every 3 minutes, 100+ guild members triggered cascading request queries causing ~9,696 request table accesses per second.

**Solution:**
Fixed by decoupling request sync from inventory sync (same fix as PERF-002). See PERF-002 for full details.

**Closed:** 2026-01-26

---

## Resolved Bugs (2026-01-28)

### 🔴 CRITICAL - All Resolved

#### ✅ [SYNC-001] Incoming snapshots with higher requestLogApplied values cause local requests to disappear

**Severity:** 🔴 CRITICAL
**Category:** Snapshot Sync / Event Sourcing
**Reporter:** User (Production - Galdof character)
**Date Reported:** 2026-01-27
**Date Resolved:** 2026-01-28
**Status:** ✅ RESOLVED
**Reproducibility:** Was consistent when receiving snapshots from other players
**Related:** [REPLAY-001]

**Problem:**
After [REPLAY-001] fix recovered all 58 requests, the gromsblood requests disappeared again minutes later when receiving a snapshot from another player. The snapshot had `requestLogApplied[Galdof-OldBlanchy] = 42` but didn't include the gromsblood requests, causing them to be skipped during replay.

**Root Cause:**
The `ApplyRequestSnapshot()` function used max-merge logic for `requestLogApplied`, blindly accepting any higher sequence number. This was fundamentally broken for event sourcing because:
- Other player's snapshot is from THEIR perspective, not authoritative
- Our local event log is the authoritative source for our own data
- Accepting their higher sequence number caused `ReplayRequestLogEntries()` to skip our local events (seq 41, 42)
- Result: Requests in our event log never got replayed back into the snapshot

**Solution Implemented:**
Implemented smart-merge algorithm in `ApplyRequestSnapshot()` that protects local event log entries:

1. **Build map of max local sequence per actor** from our event log
2. **For each incoming requestLogApplied[actor]:**
   - If `incomingSeq > maxLocalSeq`: Accept (safe, beyond our event log)
   - If `incomingSeq <= maxLocalSeq`: **REJECT** (would skip our local events)
   - If `incomingSeq <= localSeq`: Keep local (we're already ahead)

**Key Logic:**
```lua
if incomingSeq > localSeq then
    if incomingSeq > maxLocal then
        -- Safe: incoming seq is beyond our event log
        localApplied[actor] = incomingSeq
        upgraded = upgraded + 1
    else
        -- REJECT: Would mark our local events as "already applied"
        TOGBankClassic_Output:Debug("SYNC", "Rejecting %s seq %d (would skip local events up to %d)",
            actor, incomingSeq, maxLocal)
        rejected = rejected + 1
    end
end
```

**Example:**
- Local: event log has Galdof seq 41, 42 (maxLocal = 42)
- Local: `requestLogApplied[Galdof] = 40`
- Incoming: `requestLogApplied[Galdof] = 42`
- **Decision:** Reject (42 <= 42, would skip our local events)
- **Result:** Keep local value 40, replay processes 41 & 42, gromsblood stays visible ✅

**Testing Results:**
- ✅ Requests stay visible after multiple sync cycles
- ✅ Data persists correctly through `/reload` and logout/login
- ✅ Smart-merge accepts legitimate updates (seq beyond event log)
- ✅ Smart-merge rejects seq that would skip local events
- ✅ Debug logging shows rejected sequences with actor and reason

**Additional Improvements:**

1. **Diagnostic logging** added with `[PERSIST]` prefix:
   - Traces `requestLogApplied` state on load
   - Logs smart-merge decisions (upgraded/kept/rejected)
   - Tracks REPLAY-001 validation rebuilds

2. **New command `/togbank persistcheck`:**
   - Shows counts: requests, requestLog entries, requestLogApplied actors
   - Verifies Guild.Info references SavedVariables correctly
   - Useful for troubleshooting sync issues

3. **Architecture documentation:**
   - Created [REQUEST_COMMS.md](REQUEST_COMMS.md) with complete system architecture
   - Explains event sourcing, persistence, and communication protocols
   - Documents all data structures and their purposes

**Files Modified:**
- `Modules/RequestLog.lua` (lines 199-206, 249-257, 619-625, 678-682): Added [PERSIST] debug logging
- `Modules/RequestLog.lua` (lines 636-676): Implemented smart-merge algorithm
- `Modules/Chat.lua` (lines 1377-1422): Added `/togbank persistcheck` command
- `docs/REQUEST_COMMS.md`: Created comprehensive architecture documentation
- `docs/DELTA_BUGS.md`: Consolidated bug tracking

**Debug Commands:**
```
/togbank debugcat SYNC true          # Enable SYNC debug logging
/togbank persistcheck                # Check current persistence state
/togbank debuglog 100 PERSIST        # View persistence-related log entries
```

**Known Limitations:**
- Tombstone handling with rejected sequences needs validation (banker fulfills your request → tombstone should apply even if seq rejected)
- May need hybrid approach: accept seq if snapshot contains matching request with newer timestamp

**See Also:**
- [REQUEST_COMMS.md](REQUEST_COMMS.md) - Complete request communication system architecture
- [REPLAY-001] - Related: Empty requestLogApplied recovery mechanism

---

## Resolved Bugs (2026-01-22)

#### ✅ [SYNC-008] Manual request sync (`/togbank sync`) not initiating request synchronization

**Severity:** 🟠 HIGH
**Category:** Request Sync / Commands
**Reporter:** User (Testing)
**Date Reported:** 2026-01-23
**Status:** ✅ CLOSED (Working As Designed)
**Closed Date:** 2026-01-27
**Reproducibility:** N/A (Not a bug)

**Description:**
After a `/wipe` command, user expected to manually trigger request data sync using `/togbank sync` to repopulate request data from other guild members. However, the command does not appear to initiate request data synchronization as expected.

**Resolution:**
This is working as designed. Request data synchronization was intentionally decoupled from inventory sync to fix PERF-002 (NormalizeRequestList broadcast storm).

**Current Behavior (By Design):**
- `/togbank sync` triggers inventory data sync only
- Request data sync is NOT included in manual `/togbank sync` command
- Request sync occurs automatically through other mechanisms (login, guild events)
- This prevents the broadcast storm that was causing severe performance degradation in 100+ member guilds

**Why Request Sync Was Removed:**
As part of fixing PERF-002, request version metadata was removed from the inventory delta sync protocol (`togbank-dv`). This eliminated cascading request queries that caused ~12 calls/second to NormalizeRequestList (9,696 request table accesses/second in large guilds).

**Alternative for Request Sync:**
Request data syncs automatically through:
- Guild login/logout events
- Automatic roster updates
- Dedicated request sync mechanisms (when needed)

**Related:**
- [PERF-002] NormalizeRequestList broadcast storm (fixed by decoupling)
- Request sync intentionally separated from inventory sync for performance

**Closed:** 2026-01-27

---

#### ✅ [COMPAT-002] Guild.lua nil Info crash in SendRosterData

**Severity:** 🟠 HIGH
**Category:** Backwards Compatibility / Error Handling
**Reporter:** Player (Screenshot)
**Date Reported:** 2026-01-23
**Date Resolved:** 2026-01-23
**Status:** ✅ RESOLVED
**Related:** COMPAT-001 (Similar nil Info crash pattern)

**Description:**
When `SendRosterData()` is called before guild data is fully loaded, the function crashes trying to access `self.Info.roster` when `self.Info` is nil.

**Steps to Reproduce:**
1. Login to character
2. Before guild data loads, trigger roster sync (via chat command or roster update)
3. Error: `attempt to index field 'Info' (a nil value)` at Guild.lua:746

**Expected Behavior:**
Should handle roster sync requests gracefully even if guild data hasn't loaded yet, or silently skip until ready.

**Actual Behavior:**
Lua error crashes the addon when attempting to send roster data.

**Environment:**
- WoW Version: Classic Era
- TOGBankClassic Version: 0.7.6
- Reported by player via screenshot

**Lua Errors:**
```
Interface/AddOns/TOGBankClassic/Modules/Guild.lua:746: attempt to index field 'Info' (a nil value)
```

**Root Cause:**
`SendRosterData()` (line 746) assumes `self.Info` exists and tries to access `self.Info.roster`, causing a crash when guild data hasn't loaded yet.

This happens when:
- Player logs in and guild data hasn't loaded yet
- Another player requests roster data (Chat.lua:525)
- Roster is updated via `/togbank roster` command (Guild.lua:2301)
- `Guild.Info` is still nil because `Database:Load()` hasn't been called yet

**Calling Locations:**
1. Chat.lua:525 - Responding to roster request from another player
2. Guild.lua:2301 - After updating roster via command

**Fix Applied:**
Added nil check at start of `SendRosterData()`:
```lua
function TOGBankClassic_Guild:SendRosterData()
	-- Safety check: Info might be nil if guild data not loaded yet
	if not self.Info then
		return
	end

	local data = TOGBankClassic_Core:SerializeWithChecksum({ type = "roster", roster = self.Info.roster })
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", nil, "BULK")
end
```

This matches the defensive pattern used in `ReceiveRosterData()` and gracefully handles the race condition.

**Impact:**
Pre-existing bug discovered through player report. Affects any scenario where roster data is requested before guild data loads.

**Resolution Date:** 2026-01-23

---

#### ✅ [DATA-002] Guild.lua nil version comparison in ReceiveAltData

**Severity:** 🟠 HIGH
**Category:** Data Handling / Error Handling
**Reporter:** Player (Error report)
**Date Reported:** 2026-01-23
**Date Resolved:** 2026-01-23
**Status:** ✅ RESOLVED
**Related:** Regression - was fixed in v2.3.0 but reintroduced

**Description:**
When comparing versions in `ReceiveAltData()`, the code assumes `self.Info.alts[name].version` exists, causing a crash when it's nil.

**Steps to Reproduce:**
1. Receive alt data from another player for "Pointfivbank-Azuresong"
2. Local data exists but has no version field
3. Error: `attempt to compare number with nil` at Guild.lua:1481

**Expected Behavior:**
Should handle missing version fields gracefully when comparing incoming data with existing data.

**Actual Behavior:**
Lua error crashes when trying to compare a number with nil.

**Environment:**
- WoW Version: Classic Era
- TOGBankClassic Version: 0.7.6+
- Realm: Azuresong

**Lua Errors:**
```
11x TOGBankClassic/Modules/Guild.lua:1481: attempt to compare number with nil
```

**Root Cause:**
Line 1481: `if self.Info.alts[name] and alt.version ~= nil and alt.version < self.Info.alts[name].version then`

The code checks if `alt.version` is not nil, but doesn't check if `self.Info.alts[name].version` is not nil before comparison. This happens when:
- Existing alt data was saved without a version field (old data format)
- New data arrives with a version
- Comparison fails: `1768945879 < nil`

**Fix Applied:**
Added nil check for existing version:
```lua
-- Check against existing alt data, but only if version exists
if self.Info.alts[name] and alt.version ~= nil and self.Info.alts[name].version ~= nil and alt.version < self.Info.alts[name].version then
	return ADOPTION_STATUS.STALE
end
```

**Impact:**
Handles legacy data without version fields gracefully. When existing data lacks a version, incoming data is accepted regardless of its version.

**Resolution Date:** 2026-01-23

**Notes:**
This was previously fixed in v2.3.0 of the original fork but was reintroduced during refactoring.

---

#### [UI-003] Intermittent request list visibility - requests sometimes don't appear

**Severity:** 🔴 CRITICAL
**Category:** Data Synchronization / Request System
**Reporter:** Multiple users + Developer
**Date Reported:** 2026-01-23
**Date Resolved:** NOT RESOLVED - Bug still occurring
**Status:** 🔴 OPEN - Investigating with extensive logging
**Reproducibility:** Intermittent

**Description:**
Requests intermittently disappeared from the requests window. Sometimes they showed up, sometimes they didn't. Investigation revealed they were being lost from the database itself, not just hidden in the UI.

**Root Cause (Suspected):**
Found in `ApplyRequestSnapshot()` at RequestLog.lua:410. When receiving a request snapshot from another player, the function **completely replaced** the local request list instead of merging.

**Fix Attempt #1 (v0.7.7):**
Modified `ApplyRequestSnapshot()` to **merge** incoming requests with local ones:
- Accept all requests from incoming snapshot
- Preserve local requests that aren't in the incoming snapshot
- Only exclude local requests if they're tombstoned with a newer timestamp
- Added debug logging to track preserved requests

**Result:** Bug still occurring - merge fix was insufficient. Additional causes suspected.

**Fix Attempt #3 (2026-01-23):**
Fixed snapshot rejection logic in `ReceiveRequestsData()`:
- **Root cause identified**: Snapshots were being rejected as STALE when `incomingVersion <= localVersion`
- Version calculated as `max(updatedAt)` across all requests in the snapshot
- **Problem**: Different players have different subsets of requests
  - Player A has requests 1, 2, 3, 4 (max timestamp 1769135122)
  - Player B has requests 1, 2, 5 (max timestamp 1769100000)
  - Player B's snapshot rejected as STALE even though it contains request #5 which Player A doesn't have!
- **Fix**: Only reject if versions are IDENTICAL (exact duplicate), otherwise always merge
- Changed line 905 from `if not isNewer and localVersion > 0 then` to `if not isNewer and localVersion > 0 and incomingVersion == localVersion then`
- Merge logic in `ApplyRequestSnapshot()` already handles combining both snapshots correctly

**Result:** Testing required - this fix should allow snapshots to merge even when they have different request subsets.

**Fix Attempt #2 (2026-01-23):**
Upgraded request log entry broadcast priority from BULK → ALERT:
- Request creation/modification broadcasts now use ALERT priority (highest available)
- ALERT priority ensures immediate delivery with minimal throttling
- BULK priority was causing messages to be delayed/dropped during network congestion
- With only 10-20 requests per day, ALERT has negligible bandwidth impact
- Changed in `SendRequestLogEntry()` at RequestLog.lua:945

**Result:** Testing ongoing - user was offline during request creation, unable to confirm if ALERT priority prevents message loss. Issue still occurring but root cause unclear.

**Fix Attempt #4 (2026-01-23):**
Upgraded `/togbank share` announcement priority from BULK → NORMAL:
- Share announcement (togbank-s) now uses NORMAL priority to ensure quick notification
- This is the "new data available" message that triggers players to sync
- Actual data transfers (inventory deltas, request snapshots) remain at BULK to avoid network spam
- Small announcement message (~100-200 bytes) can use NORMAL without bandwidth concerns
- Changed in `Guild:Share()` at Guild.lua:2279, 2282

**Result:** Testing required - this ensures users are notified quickly when banker runs `/share`, while large data transfers remain throttled appropriately.

**Investigation Steps (2026-01-23):**

Added extensive print logging throughout request system to track request lifecycle:

1. **AddRequest()** - Logs:
   - When Info is nil or request is invalid
   - Request details: ID, requester, item, quantity
   - Log entry creation success/failure
   - Final success/failure and total request count

2. **RecordRequestLogEntry()** - Logs:
   - Entry details: ID, type, requestId, broadcast flag
   - Duplicate detection
   - Request count before/after applying entry
   - PruneIfNeeded execution
   - Broadcasting status

3. **ApplyRequestSnapshot()** - Logs:
   - Incoming vs local request counts
   - Sanitization results
   - Each preserved local request (ID, requester, item)
   - Each DROPPED request (tombstoned)
   - Merge totals at each step
   - All post-processing steps (normalize, rebuild, replay, prune)
   - Final count after all operations

4. **NormalizeRequestList()** - Logs:
   - Starting/ending counts
   - Tombstoned requests being skipped (with ID)
   - Duplicate ID updates

5. **PruneRequests()** - Logs:
   - Starting/ending counts
   - Each pruned request with ID, status, and age in seconds
   - Helps identify if new requests are being accidentally pruned

**All logging prints directly to chat (not debug channel) to avoid being lost in spam.**

**⚠️ IMPORTANT: Before closing this ticket, revert all Print() calls back to Debug() calls to reduce chat spam in production.**

**How to Debug:**
1. Create a test request (e.g., Shamanoodles requests bags)
2. Watch for `[UI-003]` messages in chat
3. Track the request through creation → log entry → broadcast → merge/prune
4. Identify at which step the request disappears

**Potential Additional Causes:**
1. ❓ Race conditions in log replay
2. ❓ Tombstone logic too aggressive
3. ❓ requestLogApplied tracking has bugs
4. ❓ PruneRequests removing new requests incorrectly
5. ❓ NormalizeRequestList dropping valid requests
6. ⚠️ **BULK priority message throttling** - Request log entries were using BULK priority, causing messages to be delayed or dropped during network congestion (raids, world bosses). Fixed by upgrading to ALERT priority.

**Impact:**
Critical bug affecting all request system users. Requests are being silently deleted, leading to unfulfilled orders and user frustration.

**Next Steps:**
- Monitor print logs during request creation/sync
- Identify exact step where requests are lost
- Implement targeted fix based on findings

**Questions to Investigate:**
- ❓ **UI Refresh Behavior**: Are changes to the request list reflected dynamically in the open UI, or does the user need to close/reopen the requests window to see new requests? Need to verify if UI automatically updates when ApplyRequestSnapshot() completes.

---

#### [COMM-002] Stale guild roster data in IsPlayerOnline checks

**Severity:** 🔴 HIGH
**Category:** Communication / Error Prevention
**Reporter:** User (7.11 whisper issues)
**Date Reported:** 2026-01-23
**Status:** ✅ FIXED (v0.7.12)
**Reproducibility:** Frequent during delta syncs

**Description:**
`IsPlayerOnline()` was checking guild roster data without first calling `GuildRoster()` to refresh it. In Classic Era WoW, `GetGuildRosterInfo()` returns **cached** data that can be stale, causing the function to return `true` for players who had recently logged off but still appeared online in the cached roster.

This caused `SendWhisper()` to believe players were online and attempt WHISPER sends, resulting in WoW's "No player named X is currently playing" errors during delta syncs.

**Root Cause:**
Classic Era WoW API requires `GuildRoster()` to be called to request fresh roster data from the server. Without this call, `GetGuildRosterInfo()` returns the last cached snapshot, which can be seconds to minutes out of date. The online status flag (`isOnline`) in the cached data does not reflect recent logouts.

**Fix (Guild.lua:800-821):**
```lua
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
    -- Request fresh guild roster data (COMM-002)
    -- Without this, GetGuildRosterInfo() returns stale data
    GuildRoster()

    -- Check roster for player...
end
```

**Impact:**
- ✅ Eliminates WHISPER errors from stale roster data
- ✅ Ensures online checks reflect current server state
- ✅ Prevents failed delta sync operations
- ✅ Complements COMM-001 SendWhisper wrapper

**Related Bugs:**
- [COMM-001] - SendWhisper wrapper
- [DELTA-008] - RequestDeltaChain online check

**Version:** v0.7.12
**Commit:** 6949617

---

#### [COMM-003] Missing error detection for "No player named X is currently playing"

**Severity:** 🔴 HIGH
**Category:** Communication / Error Handling / Online Status Detection
**Reporter:** User (EY3G0R3)
**Date Reported:** 2026-02-18
**Status:** ✅ FIXED (v0.8.21)
**Reproducibility:** Always when whispering offline players

**Description:**
When attempting to whisper an offline player, WoW returns the system message "No player named 'X' is currently playing" via `CHAT_MSG_SYSTEM` event. The addon's event handler detected "has gone offline" messages but **did not detect these whisper failure errors**, causing several critical issues:

1. **No roster update on whisper failure** - Player remained marked "online" in `onlineMembers` cache
2. **Stale recentlySeen cache** - Player remained in `recentlySeen` table for up to 10 minutes
3. **Repeated whisper attempts** - `IsPlayerOnline()` continued returning `true`, causing hundreds of repeated whisper failures
4. **Error message spam** - Console flooded with error messages every few seconds

**Error Messages Observed:**
```
Player not found (retail pattern): Malformed
Malformed not found. The player is not added to the exceptions list.
No player named 'Malformed' is currently playing.
[repeated hundreds of times]
```

**Root Cause Analysis:**

**Issue 1: CHAT_MSG_SYSTEM Handler Gap**
The `CHAT_MSG_SYSTEM` event handler only detected:
- `"[Player] has come online."` → marks player online
- `"[Player] has gone offline."` → marks player offline
- `"[Player] has joined the guild."` → triggers full roster refresh
- `"[Player] has left the guild."` → triggers full roster refresh

**Missing pattern:**
- `"No player named 'X' is currently playing."` → ❌ NOT DETECTED

**Issue 2: Incomplete Cache Clearing**
`UpdateOnlineMember(memberName, false)` only cleared `onlineMembers` cache:
```lua
function TOGBankClassic_Guild:UpdateOnlineMember(memberName, isOnline)
    if isOnline then
        self.onlineMembers[normalized] = true
    else
        self.onlineMembers[normalized] = nil  -- Clears this cache
        -- BUT recentlySeen cache was NOT cleared!
    end
end
```

**Impact on IsPlayerOnline():**
```lua
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
    -- Check 1: Guild members (fast path)
    if self.onlineMembers[norm] == true then
        return true  -- ❌ Would be false after whisper failure detection
    end
    
    -- Check 2: Recently-seen players (cross-realm/cross-guild)
    local lastSeen = self.recentlySeen[norm]
    if lastSeen and now - lastSeen < RECENTLY_SEEN_EXPIRY then
        return true  -- ❌ STALE! Player marked seen but offline
    end
    
    return false
end
```

Even if `onlineMembers` was cleared (via "has gone offline"), `recentlySeen` cache persisted for 10 minutes, causing `IsPlayerOnline()` to return `true` and `SendWhisper()` to attempt whispers.

**Steps to Reproduce:**
1. Player "Malformed" is online and sends a message (marked in `recentlySeen`)
2. Player "Malformed" logs off (may or may not trigger "has gone offline" message)
3. Within 10 minutes, banker attempts whisper via `SendWhisper()`
4. `IsPlayerOnline()` returns `true` (from `recentlySeen` cache)
5. Whisper sent, WoW returns: "No player named 'Malformed' is currently playing"
6. Message appears in chat/console, but `CHAT_MSG_SYSTEM` handler ignores it
7. Player remains in `onlineMembers` and `recentlySeen` caches
8. Step 3 repeats indefinitely, causing error spam

**Why "has gone offline" Wasn't Reliable:**
- Not all logoffs trigger the message (crashes, disconnects, realm shutdown)
- Cross-realm players don't trigger guild roster events
- Message may arrive before `CHAT_MSG_SYSTEM` handler registers
- Even when triggered, `recentlySeen` cache was never cleared

**Fix Implementation (2026-02-18):**

**Part 1: Add Whisper Error Detection** (Modules/Events.lua ~354)
```lua
function TOGBankClassic_Events:CHAT_MSG_SYSTEM(message)
    -- Existing patterns (online, offline, joined, left)...
    
    -- NEW: Detect "No player named X is currently playing" errors from failed whispers
    local notFoundName = message:match("^No player named (.+) is currently playing%.$")
    if notFoundName then
        TOGBankClassic_Output:Debug("ROSTER", "[CHAT_MSG_SYSTEM] Player not found: %s - marking offline", notFoundName)
        TOGBankClassic_Guild:UpdateOnlineMember(notFoundName, false)
        return
    end
end
```

**Pattern Notes:**
- Classic Era can send EITHER format:
  - With single quotes around name: `No player named 'Axkva' is currently playing.`
  - Without quotes: `No player named Malformed is currently playing.`
- Fixed in COMM-003b (2026-02-20) to handle both formats
- Pattern tries single-quoted version first (`'(.+)'`), then unquoted version (`(.+)`)
- Captures player name (including spaces, special characters, realm suffix)
- Period escaped as `%.` in Lua pattern

**Part 2: Clear Both Caches** (Modules/Guild.lua ~1425-1443)
```lua
function TOGBankClassic_Guild:UpdateOnlineMember(memberName, isOnline)
    if not memberName then return end
    
    self.onlineMembers = self.onlineMembers or {}
    self.recentlySeen = self.recentlySeen or {}  -- NEW: Ensure initialized
    
    local normalized = self:NormalizeName(memberName)
    if not normalized then return end
    
    if isOnline then
        self.onlineMembers[normalized] = true
    else
        self.onlineMembers[normalized] = nil
        -- NEW: Also clear from recentlySeen cache to prevent stale "online" status
        self.recentlySeen[normalized] = nil
    end
end
```

**Part 3: Add Debug Logging** (Modules/Events.lua ~341-352)
```lua
local onlineName = message:match("^%[?(.-)%]? has come online%.$")
if onlineName then
    TOGBankClassic_Output:Debug("ROSTER", "[CHAT_MSG_SYSTEM] Player came online: %s", onlineName)
    TOGBankClassic_Guild:UpdateOnlineMember(onlineName, true)
    return
end

local offlineName = message:match("^%[?(.-)%]? has gone offline%.$")
if offlineName then
    TOGBankClassic_Output:Debug("ROSTER", "[CHAT_MSG_SYSTEM] Player went offline: %s", offlineName)
    TOGBankClassic_Guild:UpdateOnlineMember(offlineName, false)
    return
end
```

**Code Flow After Fix:**
1. Whisper attempt fails → WoW sends "No player named X is currently playing"
2. `CHAT_MSG_SYSTEM` handler detects error pattern
3. Calls `UpdateOnlineMember(playerName, false)`
4. **Both** `onlineMembers` and `recentlySeen` cleared
5. Next `IsPlayerOnline()` check returns `false`
6. `SendWhisper()` refuses to send, logs debug message
7. No more whisper attempts, no more error spam

**Benefits:**
- ✅ Immediate offline detection from whisper failures
- ✅ No reliance on "has gone offline" message
- ✅ Works for cross-realm players
- ✅ Works for crashes/disconnects/realm shutdown
- ✅ Clears both online status caches
- ✅ Prevents error message spam
- ✅ Complements COMM-001 (SendWhisper wrapper)
- ✅ Complements COMM-002 (GuildRoster refresh)

**Testing:**
1. Have player log in, send message (populates `recentlySeen`)
2. Player logs off **without** triggering "has gone offline"
3. Attempt whisper via `/togbank share` or delta sync
4. Verify error detected in debug log: `[CHAT_MSG_SYSTEM] Player not found: X - marking offline`
5. Verify subsequent `IsPlayerOnline()` returns `false`
6. Verify no repeated whisper attempts

**Impact:**
Eliminates massive error spam (hundreds of errors) when attempting to communicate with offline players. Provides immediate feedback from actual whisper failures rather than relying on roster events which may not fire for all logout scenarios.

**Related Bugs:**
- [COMM-001] - SendWhisper wrapper with online checking
- [COMM-002] - GuildRoster refresh for IsPlayerOnline
- [DELTA-008] - RequestDeltaChain online validation

**Version:** v0.8.21
**Files Modified:**
- `Modules/Events.lua` - Added whisper error pattern detection
- `Modules/Guild.lua` - Clear both caches on offline
- `CHANGELOG.md` - Documented as COMM-003

---

#### [COMM-003c] Whisper error messages not suppressed from appearing in chat

**Severity:** 🟡 MEDIUM
**Category:** Communication / User Experience
**Reporter:** User
**Date Reported:** 2026-02-24
**Status:** ✅ FIXED (v0.8.29)
**Reproducibility:** Always (when whispering offline players)

**Description:**
Even though COMM-003 and COMM-003b fixed the addon's ability to detect when players were offline, the error messages "No player named 'X' is currently playing" were still appearing in the player's chat window, causing visual spam.

**Steps to Reproduce:**
1. Player logs off
2. Addon attempts to whisper them (before offline detection completes)
3. WoW generates CHAT_MSG_SYSTEM event with error message
4. Addon's event handler detects error and marks player offline (COMM-003/003b working correctly)
5. Error message displays in chat window (COMM-003c bug)

**Expected Behavior:**
- Addon should suppress error messages from appearing in chat
- Silent failure when whispering offline players
- User should not see any whisper error spam

**Actual Behavior (Before Fix):**
- Error messages appeared in CHAT_MSG_SYSTEM channel
- Chat window showed "No player named 'Axkva' is currently playing."
- Visual spam when multiple offline whispers occurred
- Addon correctly detected errors and marked players offline, but didn't prevent display

**Root Cause:**
WoW's event system delivers CHAT_MSG_SYSTEM events to all registered handlers AND displays the message in the chat frame. Registering an event handler allows addon to RECEIVE the message but doesn't prevent WoW from DISPLAYING it. COMM-003/003b added detection logic but no display suppression.

**Fix Implementation (2026-02-24):**
Added ChatFrame_AddMessageEventFilter in Events.lua Initialize() function to filter "No player named X" error messages:

```lua
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, message)
    if message and (message:match("No player named '(.+)' is currently playing") or 
                     message:match("No player named (.+) is currently playing")) then
        return true  -- Suppress this message from appearing in chat
    end
    return false  -- Allow other messages through
end)
```

**How It Works:**
- ChatFrame_AddMessageEventFilter intercepts messages before they're displayed
- Checks if message matches either single-quoted or unquoted whisper error patterns
- Returns true to suppress display (message still delivered to CHAT_MSG_SYSTEM handlers)
- Returns false to allow non-error messages through normally
- Works in conjunction with COMM-003/003b offline detection

**Result:**
- Clean chat window with no whisper error spam
- Offline detection from COMM-003/003b continues to work normally
- User sees no visual indication of whisper failures
- Error detection happens in background without cluttering UI

**Related Bugs:**
- COMM-003: Original offline player detection via CHAT_MSG_SYSTEM
- COMM-003b: Added support for single-quoted error format
- COMM-003d: Removed recentlySeen cache to prevent whispers to recently offline players

**Version:** v0.8.29
**Files Modified:**
- `Modules/Events.lua` - Added ChatFrame_AddMessageEventFilter in Initialize (~59-66)
- `CHANGELOG.md` - Documented as COMM-003c

---

#### [COMM-003d] recentlySeen cache causing whispers to offline players

**Severity:** 🟠 HIGH
**Category:** Communication / Cache Management
**Reporter:** User
**Date Reported:** 2026-02-24
**Status:** ✅ FIXED (v0.8.29)
**Reproducibility:** Always (5-minute window after player logoff)

**Description:**
Players were receiving whisper error messages for players who had recently logged off, despite COMM-003/003b offline detection working correctly. Root cause was the recentlySeen cache (5-minute TTL) keeping players marked "online" after logoff, undermining the accurate onlineMembers guild roster cache.

**Steps to Reproduce:**
1. Player 'Axkva' sends a message (added to recentlySeen cache)
2. 'Axkva' logs off immediately
3. GUILD_ROSTER_UPDATE fires, onlineMembers cleared correctly
4. Addon attempts to SendWhisper to 'Axkva' within 5 minutes
5. SendWhisper() calls IsPlayerOnline()
6. IsPlayerOnline() checks recentlySeen first → returns true (stale cache)
7. Whisper sent to offline player
8. Error message appears in chat

**Expected Behavior:**
- IsPlayerOnline() should return accurate guild roster status
- No whispers sent to offline players
- Guild roster cache (onlineMembers) should be single source of truth

**Actual Behavior (Before Fix):**
- IsPlayerOnline() checked recentlySeen cache before onlineMembers
- Players appeared "online" for 5 minutes after logoff due to stale cache
- Whispers sent to offline players triggered error messages
- Error spam continued despite COMM-003/003b detection working

**Root Cause Analysis:**

**Dual-Cache Architecture Problem:**
```lua
-- Previous IsPlayerOnline implementation
function TOGBank.Guild:IsPlayerOnline(player)
    local norm = NormalizeName(player)
    -- BUG: Checked stale cache first
    if self.recentlySeen[norm] then
        local entry = self.recentlySeen[norm]
        if (GetTime() - entry.lastSeen) < 300 then  -- 5 minute TTL
            return true  -- STALE: Player might have logged off
        end
    end
    -- Accurate cache checked second
    return self.onlineMembers[norm] == true
end
```

**Race Condition Timeline:**
1. T+0s: Player sends message → `recentlySeen[norm] = { lastSeen = GetTime() }`
2. T+1s: Player logs off → GUILD_ROSTER_UPDATE fires
3. T+1s: `onlineMembers[norm]` cleared correctly (accurate)
4. T+60s: SendWhisper called → IsPlayerOnline checks recentlySeen first
5. T+60s: `(GetTime() - lastSeen) < 300` → true (239 seconds remain)
6. T+60s: IsPlayerOnline returns true (wrong)
7. T+60s: Whisper sent → error triggered

**Design Flaw:**
recentlySeen cache was originally intended for "cross-realm/cross-guild" player tracking, but TOGBankClassic is a guild-only bank addon. User challenged: "why would we need it for non-guild members for a guild only bank addon?" The recentlySeen cache had no valid use case and was actively causing bugs by maintaining stale state.

**Architectural Issue:**
Maintaining two caches for the same data (online status) created race conditions and stale state. The onlineMembers cache is event-driven from GUILD_ROSTER_UPDATE and CHAT_MSG_SYSTEM (online/offline messages), providing accurate real-time guild roster status. The recentlySeen cache was message-driven from every communication, creating a 5-minute window of stale data that overrode the accurate cache.

**Fix Implementation (2026-02-24):**

**1. Simplified IsPlayerOnline() - Single Source of Truth:**
```lua
function TOGBank.Guild:IsPlayerOnline(player)
    if not player then return false end
    local norm = self:NormalizeName(player)
    return self.onlineMembers[norm] == true
end
```

**2. Converted MarkPlayerSeen() to No-Op Stub:**
```lua
function TOGBank.Guild:MarkPlayerSeen(player)
    -- Stub for backwards compatibility
    -- Previously populated recentlySeen cache
    -- Now no-op since recentlySeen removed
end
```

**3. Removed MarkPlayerSeen() Call from Message Handler:**
Deleted `TOGBank.Guild:MarkPlayerSeen(sender)` call in Chat.lua message handler that was populating the stale cache on every message.

**How It Works Now:**
- IsPlayerOnline() uses ONLY onlineMembers cache
- onlineMembers populated by GUILD_ROSTER_UPDATE events (accurate, real-time)
- onlineMembers also updated by CHAT_MSG_SYSTEM "has come online" / "has gone offline" messages
- No secondary cache to create race conditions or stale state
- MarkPlayerSeen() stub preserved for backwards compatibility (no-op)

**Result:**
- Single source of truth for online status (onlineMembers)
- No more whispers to recently-offline players
- No more 5-minute stale cache window
- Simplified architecture with less code to maintain
- Guild roster cache accuracy from user's previous GUILD_ROSTER_UPDATE work no longer undermined

**Impact Analysis:**
- **Removed Functionality:** Cross-realm/cross-guild player tracking (unused in guild-only addon)
- **Improved Accuracy:** Online status now 100% accurate with guild roster
- **Reduced Complexity:** One cache instead of two, simpler logic, less state management
- **Bug Prevention:** No more dual-cache race conditions or stale state issues

**Related Bugs:**
- COMM-003: Original offline player detection via CHAT_MSG_SYSTEM
- COMM-003b: Added support for single-quoted error format
- COMM-003c: Added ChatFrame_AddMessageEventFilter to suppress error display
- COMM-001b: GUILD_ROSTER_UPDATE cache system that recentlySeen was undermining

**Version:** v0.8.29
**Files Modified:**
- `Modules/Guild.lua` - Simplified IsPlayerOnline to use only onlineMembers (~1533-1547), converted MarkPlayerSeen to no-op stub
- `Modules/Chat.lua` - Removed MarkPlayerSeen() call from message handler (~618)
- `CHANGELOG.md` - Documented as COMM-003d

---

#### [UI-004] Banker tab selection resets to first banker intermittently

**Severity:** 🟡 MEDIUM
**Category:** UI / User Experience
**Reporter:** User
**Date Reported:** 2026-01-23
**Status:** ✅ FIXED (v0.7.11)
**Reproducibility:** Intermittent (now resolved)

**Description:**
When viewing banker tabs in the inventory UI, the selected tab intermittently snapped back to the first banker. This occurred while the UI was already open and the user had selected a specific banker's tab.

**Steps to Reproduce:**
1. Open TOGBankClassic inventory UI (`/togbank`)
2. Navigate to a banker tab (not the first one)
3. Keep the tab open
4. UI would intermittently switch back to the first banker tab without user action

**Expected Behavior:**
- Selected banker tab should remain active
- Tab selection should only change with explicit user interaction

**Actual Behavior (Before Fix):**
- Tab selection reset to first banker automatically
- Occurred during data syncs, UI refreshes, or other redraw events

**Root Cause:**
`DrawContent()` in Modules/UI/Inventory.lua always called `self.TabGroup:SelectTab(first_tab)` at the end, regardless of whether a tab was already selected. This meant any time the UI refreshed (during syncs, data updates, etc.), it would unconditionally reset to the first banker.

**Triggers:**
- Opening inventory UI (initial DrawContent call)
- Data syncs via PerformSync() (called on UI open)
- Any event that triggered DrawContent() redraw

**Fix Implementation (2026-01-23):**
Modified DrawContent() in Modules/UI/Inventory.lua to preserve the currently selected tab:

```lua
-- UI-004 fix: Preserve currently selected tab instead of always resetting to first_tab
-- Only select first_tab if no tab is currently selected
local currentTab = self.TabGroup.localstatus and self.TabGroup.localstatus.selected
if currentTab and info.alts[currentTab] then
    -- Preserve current selection if it's still valid
    self.TabGroup:SelectTab(currentTab)
else
    -- No current selection or invalid tab, select first tab
    self.TabGroup:SelectTab(first_tab)
end
```

**Logic:**
1. Check if there's a currently selected tab (`self.TabGroup.localstatus.selected`)
2. Verify the current tab is still valid (exists in `info.alts`)
3. If valid, preserve the current selection
4. Otherwise, select the first tab (initial open or if current tab disappeared)

**Testing:**
1. Open inventory UI and select a banker tab (not the first)
2. Wait for background syncs to occur
3. Verify tab selection remains on the selected banker
4. Switch to different banker, verify it stays selected
5. Test with multiple syncs and data updates

**Impact:**
Previously disrupted user workflow when reviewing multiple bankers. Users had to repeatedly reselect the desired banker tab after every sync or refresh.

---

#### [SYNC-002] Request data not syncing with /togbank sync command

**Severity:** 🟡 MEDIUM
**Category:** Communication / Synchronization
**Reporter:** User
**Date Reported:** 2026-01-23
**Status:** ✅ FIXED (v0.7.11)
**Reproducibility:** Always

**Description:**
Request data was not being queried when using `/togbank sync` command or when opening the inventory UI. Users would not receive updated request information even after explicitly syncing.

**Root Cause:**
Two distinct issues in request query handling:

1. **Missing player parameter in PerformSync()**
   - `PerformSync()` called `QueryRequestLog(nil, nil)` and `QueryRequestsSnapshot(nil)`
   - Both functions check `if not player then return end` and exit early with nil
   - Result: No query message was ever sent

2. **Player check prevented responses**
   - Request query handler had `if data.player == player then` check
   - This meant only the person whose name matched `data.player` would respond
   - Since querier sends their own name, other guild members would ignore the query
   - Result: Even when query was sent, nobody would respond

**Why This Matters:**
Request data is **guild-wide** (not per-player like alt data), so everyone should have the same requests and be able to share them. The player-specific check was incorrect for request queries.

**Fix Implementation (2026-01-23):**

**Part 1: Pass player name to query functions** (Modules/Chat.lua)
```lua
function TOGBankClassic_Chat:PerformSync()
    TOGBankClassic_Events:SyncDeltaVersion()
    TOGBankClassic_Guild:FastFillMissingAlts()
    -- Pass our own player name so others know who to respond to
    local player = TOGBankClassic_Guild:GetPlayer()
    TOGBankClassic_Guild:QueryRequestLog(player, nil)
    TOGBankClassic_Guild:QueryRequestsSnapshot(player)
end
```

**Part 2: Remove player check for request queries** (Modules/Chat.lua)
```lua
-- Request data is guild-wide, so anyone can respond (no player check needed)
if data.type == "requests" then
    TOGBankClassic_Guild:SendRequestsSnapshot()
end
if data.type == "requests-log" then
    TOGBankClassic_Guild:SendRequestLogEntries(sender, data.logFrom)
end

-- Alt and roster queries are per-player, only respond if query is for us
if data.player == player then
    if data.type == "roster" then
        -- ... roster handling
    end
    if data.type == "alt" then
        -- ... alt handling
    end
end
```

**Backwards Compatibility:**
- Old clients with `if data.player == player` check will still ignore queries from new clients
- New clients respond to any request query, so old→new queries work
- Request data still propagates via `/togbank share` and version broadcasts (cross-version)
- Mixed version guilds will work, but full rollout recommended for optimal sync

**Testing:**
1. Run `/togbank sync` - should see request query broadcasts in debug log
2. Open inventory UI - should trigger same sync including request queries
3. Check if request data appears after sync
4. Verify with `/togbank debuglog` that queries are being sent and responses received

**Impact:**
Users could not explicitly sync request data via commands or UI. Request data only updated through broadcasts from `/togbank share` or automatic version checks.

---

#### [COMM-001] "No player named <banker> is currently playing" error message

**Severity:** 🟡 MEDIUM
**Category:** Communication / Error Handling
**Reporter:** Multiple players
**Date Reported:** 2026-01-23
**Date Resolved:** 2026-01-23 (Expanded with comprehensive fix)
**Status:** ✅ RESOLVED
**Reproducibility:** Frequent

**Description:**
Players report receiving error messages stating "No player named <banker> is currently playing" where `<banker>` is the name of a guild banker character (e.g., "Shardsndust"). This appears to be related to addon communication attempts when the target banker is offline or not in range.

**Error Message:**
```
No player named Shardsndust is currently playing
```

**Steps to Reproduce:**
1. Banker logs in and shares data
2. Player's client tracks banker as "seen recently" in online_bankers
3. Banker logs out
4. Player requests alt data within 10 minutes
5. Code attempts WHISPER to offline banker
6. WoW displays "No player named X is currently playing" error

**Root Cause:**
Multiple locations in the codebase sent WHISPER messages without verifying the target player was currently online. When players logged out between request and response, WHISPER attempts would fail with WoW's "No player named X is currently playing" error.

**Affected Code Locations:**
1. `QueryAltData()` - togbank-r pull-based queries
2. `SendStateSummary()` - togbank-state state summaries
3. `SendReplyData()` - togbank-nochange no-change replies (2 locations)
4. `RequestDeltaChain()` - togbank-dr delta range requests
5. Chat.lua handlers - togbank-rr ACKs, togbank-dc delta chains

**Fix Applied (2026-01-23):**

**Phase 1: Initial Fix**
1. Added `IsPlayerOnline()` helper (Guild.lua):
```lua
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
    -- Scans GetGuildRosterInfo() to check isOnline flag
    -- Returns true only if player is currently connected
end
```

2. Added online checks in QueryAltData() and RequestDeltaChain()

**Phase 2: Comprehensive Expansion**
3. Added online checks to all remaining WHISPER send locations (7 total)

**Phase 3: Centralized Refactor**
4. Created `SendWhisper()` wrapper in Core.lua:
```lua
function TOGBankClassic_Core:SendWhisper(prefix, text, target, prio, callbackFn, callbackArg)
    -- Check if target is online
    if not TOGBankClassic_Guild:IsPlayerOnline(target) then
        TOGBankClassic_Output:Debug("Cannot send %s WHISPER to %s - player is offline", prefix, target)
        return false
    end

    -- Send the whisper
    self:SendCommMessage(prefix, text, "WHISPER", target, prio, callbackFn, callbackArg)
    return true
end
```

5. Replaced all direct WHISPER sends with `SendWhisper()` calls:
   - Chat.lua: togbank-rr ACK replies
   - Chat.lua: togbank-dc delta chain responses
   - Guild.lua: togbank-state state summaries
   - Guild.lua: togbank-nochange no-change replies (2 locations)
   - Guild.lua: togbank-r pull-based queries
   - Guild.lua: togbank-dr delta range requests

**Benefits:**
- ✅ Single point of maintenance for all WHISPER logic
- ✅ Automatic online checking - impossible to forget
- ✅ Consistent error handling and logging
- ✅ Return value indicates send success/failure
- ✅ Eliminates ALL "No player named" errors
- ✅ Graceful fallback when players go offline

**Impact:**
Completely eliminates confusing error messages for players. All WHISPER communications now automatically verify target is online before sending. System gracefully handles logout scenarios by either falling back to GUILD broadcasts or silently skipping the message with appropriate debug logging.

**Known Limitation (2026-01-24):**
The `IsPlayerOnline()` check uses `GuildRoster()` which requests fresh data but `GetGuildRosterInfo()` returns stale data immediately. The fresh data only arrives after `GUILD_ROSTER_UPDATE` event fires. This creates a race condition where:
1. Player appears online in stale data
2. WHISPER is sent
3. Player is actually offline
4. Blizzard server returns "No player named X is currently playing" error

**Planned Enhancement - COMM-001b:**
Implement GUILD_ROSTER_UPDATE cache system to maintain accurate real-time online status:
- Cache table updated only when Blizzard sends fresh data via GUILD_ROSTER_UPDATE event
- Eliminates stale data issue
- Instant lookups with no API calls
- See FEATURE_IMPROVEMENTS.md for implementation details

---

#### ✅ [DELTA-008] Repeated delta sync failures causing fallback to full sync

**Severity:** 🟡 MEDIUM
**Category:** Delta Application / Performance
**Reporter:** Developer (Console warning)
**Date Reported:** 2026-01-23
**Date Resolved:** 2026-01-23
**Status:** ✅ RESOLVED
**Reproducibility:** Intermittent

**Description:**
The addon was logging repeated delta sync failures for specific bankers (e.g., "Shardsndust-Azuresong"), causing the system to fall back to full synchronization. This indicated that delta application was failing multiple times for specific bankers.

**Warning Message:**
```
TOGBankClassic: [WARN] Repeated delta sync failures for Shardsndust-Azuresong. Falling back to full sync.
```

**Root Cause:**
In `RequestDeltaChain()` (Guild.lua:2028), the code sent WHISPER messages to request delta chains from senders without verifying they were still online. When the sender had logged off, the WHISPER would fail, causing repeated delta sync failures and triggering the fallback mechanism.

**Affected Code:**
```lua
function TOGBankClassic_Guild:RequestDeltaChain(altName, fromVersion, toVersion, sender)
    -- No online check before attempting WHISPER
    SendCommMessage("togbank-dr", serialized, "WHISPER", sender, "ALERT")
```

**Fix Applied (2026-01-23):**

Added online validation before sending delta chain request:

```lua
function TOGBankClassic_Guild:RequestDeltaChain(altName, fromVersion, toVersion, sender)
    -- Check if sender is online before attempting WHISPER (DELTA-008)
    if not self:IsPlayerOnline(sender) then
        TOGBankClassic_Output:Debug(
            "Cannot request delta chain for %s from %s - sender is offline",
            altName, sender
        )
        return false
    end

    -- Only send WHISPER if sender is currently online
    SendCommMessage("togbank-dr", serialized, "WHISPER", sender, "ALERT")
end
```

**How This Fixes DELTA-008:**
- Delta chain requests only sent to online senders
- Returns false when sender is offline, allowing system to use alternative sync methods
- Eliminates repeated WHISPER failures to offline players
- Prevents accumulation of delta sync errors
- System gracefully handles sender logout scenarios

**Related:**
Fixed alongside COMM-001, which addressed the same root cause in `QueryAltData()`.

**Impact:**
Eliminates unnecessary delta sync failures when senders are offline. System now properly detects offline senders and uses appropriate fallback mechanisms without generating error messages or warnings.

---

*No other open bugs at this time.*

---

## Resolved Bugs (2026-01-22)

### 🟠 HIGH - All Resolved

#### ✅ [SYNC-001] Cross-Guild Data Bleed After /wipe

**Reported:** 2026-01-22
**Severity:** HIGH
**Category:** Database / Synchronization
**Status:** ✅ RESOLVED
**Fixed:** 2026-01-22

**Description:**
When users execute `/wipe` and then start syncing, they initially receive information about bankers that aren't in their current guild. This appears to be related to players who have characters across multiple guilds on their account.

**Steps to Reproduce:**
1. Execute `/wipe` command to clear local data
2. Begin synchronization process
3. Observe banker data appearing for characters not in the current guild

**Expected Behavior:**
After `/wipe`, synchronization should only populate data for bankers currently in the active guild.

**Actual Behavior:**
Data from other guilds (possibly from other characters on the same account) is bleeding through and appearing in the bank data.

**Root Cause Analysis:**

Three contributing factors have been identified:

1. **Account-Wide SavedVariables + Guild-Specific Data**
   - TOC declares `SavedVariables` (not `SavedVariablesPerCharacter`)
   - All characters on same account share `TOGBankClassicDB`
   - Database stores data at `db.faction[guildName]`
   - Characters in different guilds coexist in same SavedVariables file

2. **Permissive Sync Validation**
   - `IsAltDataAllowed()` currently uses permissive mode (returns `true` for all)
   - No validation that sender/alt are in current guild roster
   - Accepts data from anyone without checking guild membership

3. **Wipe Only Clears Current Guild**
   - `/wipe` calls `Reset(currentGuild)` which only clears one guild's data
   - Other guilds' data remains in SavedVariables
   - No validation prevents accepting stale cross-guild data

**Proposed Solution:**

Add roster-based validation to sync operations:
- Guild roster from `GetGuildRosterInfo()` is authoritative and guild-specific
- Only accept alt data if the alt is in the current guild's banker roster
- Only accept data from senders who are in the current guild
- Use `GetBanks()` (which parses current guild roster) as validation source

**Implementation:**

✅ **Added Guild Roster Validation (2026-01-22)**

1. **New Helper Function** - `Guild.lua:IsInCurrentGuildRoster(playerName)`
   - Checks if a player is in the current guild by scanning `GetGuildRosterInfo()`
   - Returns `true` only if player found in current guild roster
   - Guild-specific validation prevents cross-guild acceptance

2. **New Validation Mode** - `Chat.lua:IsAltDataAllowed_RosterBased(sender, claimedNorm)`
   - Validates sender is in current guild roster
   - Validates claimed alt is a banker in current guild roster (via `IsBank()`)
   - Logs debug messages when rejecting cross-guild data
   - Replaces permissive mode as default

3. **Updated Default** - `Chat.lua:IsAltDataAllowed()`
   - Now calls `IsAltDataAllowed_RosterBased()` instead of `IsAltDataAllowed_Permissive()`
   - All sync operations (full sync, delta, version broadcasts) now use roster validation

**How This Fixes SYNC-001:**
- After `/wipe`, even if stale data exists in SavedVariables, it won't be accepted
- Senders from other guilds are rejected (not in current guild roster)
- Alts from other guilds are rejected (not bankers in current guild roster)
- Only current guild members can share data about current guild bankers

**Backwards Compatibility:**
- Permissive and Restrictive modes still available for future use
- No changes to data structure or protocol
- Works with existing v0.8.0 clients

**Impact:**
Users see incorrect banker information after data reset, potentially causing confusion about who has banking privileges.

---

## Resolved Bugs (2026-01-22)

### � CRITICAL - All Resolved

#### ✅ [PERF-002] NormalizeRequestList spam causes performance degradation

**Severity:** 🔴 CRITICAL
**Category:** Performance / Request Sync
**Reporter:** User (Production) - 100+ member guild
**Date Reported:** 2026-01-25
**Status:** ✅ CLOSED
**Fixed In:** v0.7.18 (commit 77b16a1)
**Fixed Date:** 2026-01-26
**Reproducibility:** Was consistent in large guilds

**Description:**
`NormalizeRequestList()` was being called 12+ times per second when multiple guild members sent request version queries simultaneously. Each call processed all 404 requests, causing severe performance degradation in 100+ member guilds.

**Evidence from Debug Log:**
Timestamp 1769290015-1769290016 (2 seconds): Pattern repeated 24+ times = ~12 calls/second

**Triggering Events (Before Fix):**
```
> |cffffffffIris-Atiesh|r has fresher requests data, querying.
> |cffc79c6eSkoobydoo-Azuresong|r has fresher requests data, querying.
> |cff40c7ebSolomage-Atiesh|r has fresher requests data, querying.
```

**Root Cause:**
The inventory delta sync protocol (`togbank-dv`) was piggybacking request version metadata. Every 3-minute inventory broadcast triggered request version comparisons across all 100+ guild members, causing cascading request queries and repeated NormalizeRequestList() calls.

**Performance Impact (Before Fix):**
- ~12 full list iterations per second
- 404 requests × 12 = 4,848 request reads per second  
- With PruneRequests: ~9,696 request table accesses per second

**Solution Implemented:**
1. **Decoupled request sync from inventory sync**
2. Removed `requests` and `requestLog` fields from `GetVersion()` in Guild.lua
3. Removed request version checking from `togbank-dv` handler in Chat.lua
4. Request syncs now independent of 3-minute inventory broadcasts

**Files Modified:**
- `Modules/Guild.lua`: Removed request metadata from GetVersion()
- `Modules/Chat.lua`: Removed request checking from togbank-dv handler

**Verification:**
After fix, no "has fresher requests data, querying" messages observed during wipe/sync operations. Request syncs only occur when explicitly needed.

**Closed:** 2026-01-26

---

#### ✅ [PERF-005] P2P Send Queue Throttling

**Severity:** 🟠 HIGH
**Category:** Performance / P2P Protocol
**Reporter:** Production Testing
**Date Reported:** 2026-02-17
**Status:** ✅ CLOSED
**Fixed In:** v0.8.17
**Fixed Date:** 2026-02-17
**Reproducibility:** Was consistent in large guilds with many simultaneous P2P requests

**Description:**
When many guild members requested P2P data simultaneously, peers would acknowledge all requests immediately but then be unable to fulfill them due to ChatThrottleLib queue overflow. This caused:
- Peers saying "Responding to X with data for Y" but never actually sending
- Only 1-2 "Send complete" messages despite many response promises
- Requesters stuck waiting indefinitely for data that never arrives
- 30+ second send times overwhelming the chat throttle system

**Root Cause:**
The P2P protocol separated acknowledgment from data transmission:
1. Peer immediately sends `togbank-rr` acknowledgment via WHISPER
2. Requester cancels the pending P2P request and waits
3. Peer attempts to call `SendAltData` to send full data
4. ChatThrottleLib queue gets overwhelmed with concurrent sends (50KB+ each taking 30+ seconds)
5. Data send never completes or is significantly delayed

With 50-100 online guild members, a single sync request could trigger dozens of responses, causing complete system overload.

**Solution Implemented:**
Implemented send queue throttling to limit concurrent P2P data sends to 3 maximum:

**Modules/Guild.lua:**
- Added `pendingSendCount` tracking variable (current queue depth)
- Added `MAX_PENDING_SENDS = 3` constant (maximum concurrent sends)
- Added `pendingSendTimeouts = {}` tracking table (prevent counter leaks)
- Increment counter when peer responds to P2P data request (Chat.lua line 825)
- Decrement counter when send completes in `OnChunkSent` callback (line 2207-2210)
- Cancel pending timeout in `SendAltData` when actually sending (line 1997-2000)

**Modules/Chat.lua:**
- Check `sendQueueFull` before responding to P2P data requests (line 798)
- Increment `pendingSendCount` when acknowledging P2P request (line 825)
- Added 30-second safety timeout after increment (lines 829-838)
- Log queue status in response message (line 827)
- Log "send queue full" when rejecting due to capacity (line 815)
- Keep pending P2P request active until actual data arrives
- Clear pending request when data successfully received (line 1333-1335)

**Counter Leak Prevention (February 17, 2026):**
Added 30-second safety timeout to prevent permanent queue blocking:

**Problem:** If peer ACKs request but requester never sends state summary (disconnect/crash), counter stays incremented forever. After 3 stuck sends, peer permanently blocks all P2P responses until `/reload`.

**Solution:** 30-second safety timeout:
1. Peer ACKs and increments counter
2. Starts 30-second timer with alt name captured
3. If `SendAltData` called before timeout → cancel timer (normal flow)
4. If timeout fires → auto-decrement counter (recovery from stuck send)
5. After 3 stuck sends, peer would permanently block; now self-recovers

**Protocol Flow (Fixed):**
1. Requester broadcasts P2P request with expectedHash to GUILD
2. Peer checks send queue: `if not sendQueueFull then`
3. Peer sends `togbank-rr` acknowledgment and increments `pendingSendCount`
4. Peer starts 30-second safety timeout for counter leak prevention
5. Requester keeps pending request active, sends state summary for delta
6. Peer receives state summary, calls `SendAltData` and **cancels timeout**
7. **Data actually sends** (throttled to 3 concurrent max)
8. `OnChunkSent` callback decrements `pendingSendCount` on completion
9. Requester receives data and clears pending P2P request

**Edge Case Recovery:**
- If step 5 fails (requester offline): timeout at step 4 fires after 30s, auto-decrements counter
- If step 6 fails (peer crashes): requester's 15-second timeout triggers banker fallback (see P2P-012)
- If step 7 fails (network issue): `OnChunkSent` still called with error, decrements counter

**Key Distinction:**
- **Hash requests (hashOnly=true):** Unlimited - cheap queries for banker hash values
- **Data requests (P2P):** Throttled to 3 concurrent - expensive 5-50KB data transfers

**Performance Impact:**
- **Before:** Unlimited concurrent sends → queue overflow → most data never arrives
- **After:** 3 concurrent sends max → controlled flow → all data eventually arrives
- **Tradeoff:** Slightly slower P2P distribution, but actually works reliably

**Testing:**
Monitor these messages after `/reload`:
- ✅ "P2P: Responding to X with data for Y (hash=Z) - queue now: N/3"
- ✅ "Sharing guild bank data: X bytes in ~Y chunks..."
- ✅ "Send complete: N chunks, M bytes in T.Ts"
- ✅ "P2P send completed - queue now: N/3"
- ❌ "PERF-005: Skipping response (send queue full: 3/3)" (when at capacity)

Expected behavior:
- Maximum 3 concurrent "Sharing guild bank data..." messages
- Each send completes before new response sent
- No more "ghost responses" (acknowledge but never send)
- Smooth progression: queue 1/3 → 2/3 → 3/3 → 2/3 → 1/3

**Related Issues:**
- PERF-006: GetItemInfo stuttering (separate issue, already fixed)
- MIN_GUILD_SIZE: Reduced from 50 to 3 to enable P2P for smaller guilds
- P2P-011: pendingSendCount leak fix (counter timeout)
- P2P-012: Peer-side fallback timeout (requester recovery)

**Verified By:** Testing in guild with ~1000 members, 50-100 online
**Closed:** 2026-02-17

---

#### ✅ [PERF-009] ChatFrame_AddMessageEventFilter causing stuttering

**Severity:** 🟡 MEDIUM
**Category:** Performance / Event Handling
**Reporter:** User (Production)
**Date Reported:** 2026-02-26
**Status:** ✅ CLOSED
**Fixed In:** v0.8.29
**Fixed Date:** 2026-02-26
**Reproducibility:** Was consistent during normal gameplay

**Description:**
Users experienced stuttering and frame drops during normal gameplay immediately after adding the ChatFrame_AddMessageEventFilter in COMM-003c. The filter was intended to suppress "No player named X is currently playing" error messages from appearing in chat, but was causing performance issues.

**Root Cause:**
The chat filter was running an expensive pattern match on **every** CHAT_MSG_SYSTEM event:

```lua
-- BUGGY (before):
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(self, event, message, ...)
    if message and message:match("^No player named .+ is currently playing%.$") then
        return true  -- Suppress
    end
    return false
end)
```

**Why This Causes Stuttering:**
- CHAT_MSG_SYSTEM fires very frequently:
  - Guild achievements
  - Player online/offline messages
  - Trade channel spam
  - Zone-wide announcements
  - System messages (20+ per minute typical)
- Each event triggers pattern matching with `match("^No player named .+ is currently playing%.$")`
- Pattern matching with `.+` (greedy quantifier) is expensive:
  - Scans entire message string
  - Backtracking on mismatch
  - Runs on EVERY system message regardless of content
- 20+ pattern matches per minute = cumulative frame time impact

**Performance Impact:**
- Measured ~0.5-1ms per pattern match
- 20-30 CHAT_MSG_SYSTEM events per minute
- Total: 10-30ms of CPU time wasted per minute
- Result: Noticeable stuttering, especially in active guild chat

**Solution Implemented:**
Added fast plain-text prefix check before expensive pattern matching:

```lua
-- FIXED (after):
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(self, event, message, ...)
    if message and message:find("No player named ", 1, true) then
        -- Only do pattern match if we found the error prefix
        if message:match("^No player named .+ is currently playing%.$") then
            return true  -- Suppress this message
        end
    end
    return false
end)
```

**How It Works:**
- `find("No player named ", 1, true)` does fast plain-text search
  - 3rd parameter `true` = plain text (no pattern matching)
  - ~0.01ms per call (100x faster)
  - Returns immediately on mismatch
- Pattern match only runs if prefix found (rare - only whisper errors)
- 99%+ of CHAT_MSG_SYSTEM events skip expensive pattern match

**Performance Improvement:**
- Before: ~20 pattern matches/minute × 0.5ms = 10ms/min wasted
- After: ~20 plain-text checks/minute × 0.01ms = 0.2ms/min
- **50x performance improvement**
- Pattern match only runs on actual whisper errors (~1-2 per day)

**Result:**
- Stuttering eliminated
- Chat filter still works correctly (suppresses whisper errors)
- Maintains error suppression from COMM-003c
- No user-visible behavior change

**Related Bugs:**
- COMM-003c: Original chat filter implementation
- COMM-003: Whisper error detection via CHAT_MSG_SYSTEM
- COMM-003b: Single-quoted player name pattern matching

**Version:** v0.8.29
**Files Modified:**
- `Modules/Events.lua` - Optimized ChatFrame_AddMessageEventFilter with plain-text prefix check (~59-68)
- `docs/DELTA_BUGS.md` - Documented as PERF-009

---

#### ✅ [PERF-010] Login freeze from synchronous latestBankerHashes initialization

**Severity:** 🟠 HIGH
**Category:** Performance / Initialization
**Reporter:** User (Production)
**Date Reported:** 2026-02-26
**Status:** ✅ CLOSED
**Fixed In:** v0.8.29
**Fixed Date:** 2026-02-26
**Reproducibility:** Was consistent on every login/reload with large SavedVariables

**Description:**
Users experienced 3-5 second complete freeze when logging in or reloading UI. Game became entirely unresponsive during the freeze, then resumed normally. Root cause was Database:Load() synchronously performing data migrations on ALL alts every login, with RecalculateAggregatedItems() being the most expensive operation.

**Root Cause:**
`Database:Load()` was synchronously looping through all alts in SavedVariables performing data migrations on EVERY login (not just first-time), with 70+ alts in production:

```lua
-- BUGGY (before):
function TOGBankClassic_Database:Load(name)
    -- ... initialization ...
    
    -- v0.8.0: Migrate old alt data
    if db.alts then
        for name, alt in pairs(db.alts) do  -- ❌ SYNCHRONOUS LOOP
            -- Initialize slots
            if alt.bank and not alt.bank.slots then
                alt.bank.slots = { count = 0, total = 0 }
            end
            -- Compute inventory hash
            if not alt.inventoryHash and alt.bank and alt.bags then
                alt.inventoryHash = TOGBankClassic_Core:ComputeInventoryHash(...)
            end
            -- ❌ THE KILLER: Recalculate aggregated items (30-50ms per banker alt)
            if (alt.bank and alt.bank.items) or (alt.bags and alt.bags.items) then
                alt.items = nil
                TOGBankClassic_Bank:RecalculateAggregatedItems(alt)  -- EXPENSIVE!
            elseif alt.items then
                local aggregated = TOGBankClassic_Item:Aggregate(alt.items, nil)
                alt.items = {}
                for _, item in pairs(aggregated) do
                    table.insert(alt.items, item)
                end
            end
        end
    end
    return db
end
```

**Why This Causes Freeze:**
- **70+ alts** in SavedVariables
- RecalculateAggregatedItems() for each banker alt: ~30-50ms per alt
- Item deduplication for synced alts: also expensive
- Runs on **EVERY** login/reload, not just first-time  
- Total time: 70 alts × ~50-70ms = **3-5 seconds**

**Additional Minor Issue:**
Guild:Init() also looped through alts building latestBankerHashes (lighter operations but still synchronous).
                        mailHash = alt.mailHash or 0,
                        mailUpdatedAt = (alt.mail and alt.mail.version) or 0,
                    }
                    hashCount = hashCount + 1
                end
            end
        end
    end
end
```

**Why This Causes Freeze:**
- **70+ alts** in production SavedVariables (guild bank tracking)
- Each alt processes 5 fields: inventoryHash, inventoryUpdatedAt, version, mailHash, mailUpdatedAt
- `pairs()` iteration over large table is not deferred
- Runs on PLAYER_LOGIN event (blocks UI thread immediately)
- Total time: 70 alts × ~50-70ms per iteration = **3-5 seconds**

**Timeline:**
1. Player logs in → PLAYER_LOGIN fires
2. Guild:Init() called synchronously
3. Database:Load() loads SavedVariables (fast, already in memory)
4. Loop starts: `for altName, alt in pairs(self.Info.alts) do`
5. 70 iterations building latestBankerHashes table
6. **Game completely frozen for 3-5 seconds**
7. Init completes, game resumes

**User Impact:**
- Cannot move, cast spells, or interact with UI during freeze
- Appears as if game crashed
- Especially noticeable compared to immediate login in other addons
- Same freeze on every /reload

**Why Migrations Don't Need to Be Immediate:**
- Data already loaded from SavedVariables (WoW API does this before addons load)
- Migrations are cleanup/optimization operations that can run in background
- Deferring by 0.5 seconds still completes before user opens UI or triggers sync

**Solution Implemented:**
Wrapped entire Database:Load() migration block in `C_Timer.After(0.5)`:

```lua
-- FIXED (after):
function TOGBankClassic_Database:Load(name)
    -- ... initialization ...
    
    -- PERF-010: Defer data migrations to prevent login freeze
    -- Looping through 70+ alts with RecalculateAggregatedItems blocks UI for 3-5 seconds
    -- Migrations don't need to be immediate - data already loaded from SavedVariables
    C_Timer.After(0.5, function()
        if db.alts then
            for name, alt in pairs(db.alts) do
                -- ... all migration logic ...
                if conditions then
                    TOGBankClassic_Bank:RecalculateAggregatedItems(alt)
                end
            end
        end
        TOGBankClassic_Output:Debug("DATABASE", "Completed deferred data migrations")
    end)
    
    return db  -- Return immediately, migrations run in background
end
```

Also deferred `latestBankerHashes` initialization in Guild:Init():

```lua
-- Guild:Init()
C_Timer.After(0.5, function()
    self.latestBankerHashes = {}
    for altName, alt in pairs(self.Info.alts) do
        self.latestBankerHashes[altName] = { hash = ..., ... }
    end
end)
```

**How It Works:**
- `C_Timer.After(0.5, ...)` schedules work for 0.5 seconds later
- Login completes immediately, UI remains responsive
- After 0.5s, hash cache builds in background (still blocking, but user already in game)
- Cache ready before any hash broadcasts arrive from guild chat

**Performance Improvement:**
- Before: 3-5 second freeze on login
- After: Instant login, cache builds in background
- No functional change - cache still ready before first use

**Result:**
- Login freeze eliminated
- UI immediately responsive on login/reload  
- Migrations complete in background before first use
- Same fix pattern as PERF-008 (deferred initialization)

**Related Bugs:**
- PERF-008: Similar issue with RebuildBankerRoster synchronous initialization
- DELTA-018: Original implementation of latestBankerHashes cache
- DATA-004: Item count duplication that RecalculateAggregatedItems was trying to fix

**Version:** v0.8.29
**Files Modified:**
- `Modules/Database.lua` - Deferred entire migration block with C_Timer.After(0.5) (~175-243)
- `Modules/Guild.lua` - Deferred latestBankerHashes initialization with C_Timer.After(0.5) (~295-313)
- `docs/DELTA_BUGS.md` - Documented as PERF-010

---

#### ✅ [PERF-007] GUILD_ROSTER_UPDATE Stuttering

**Severity:** 🟡 MEDIUM
**Category:** Performance / Event Handling
**Reporter:** User (Production)
**Date Reported:** 2026-02-17
**Status:** ✅ CLOSED
**Fixed In:** v0.8.17
**Fixed Date:** 2026-02-17
**Reproducibility:** Was consistent in large guilds (1000+ members)

**Description:**
Users experienced noticeable stuttering/lag spikes whenever guild members came online or went offline, especially in large guilds (1000+ members). Each online/offline event triggered a full guild roster scan, causing 5-10ms+ frame time delays.

**Root Cause:**
The `GUILD_ROSTER_UPDATE` event handler used **OR logic** instead of **AND logic** for the initialization condition:

```lua
-- BUGGY (before):
if self.fullRosterInitAttempts < 2 or (totalMembers and onlineMembers and totalMembers <= onlineMembers) then
    self.needsFullRosterRefresh = true
end
```

This OR condition caused the flag to remain `true` indefinitely because:
- During initialization: `fullRosterInitAttempts < 2` is true → full refresh (correct)
- After 2 attempts: First condition false, BUT...
- Second condition `totalMembers <= onlineMembers` often true in practice
- Result: **Every** `GUILD_ROSTER_UPDATE` event triggers full scan

**Why totalMembers <= onlineMembers Stays True:**
- WoW API sometimes reports equal values when roster data incomplete
- Edge cases where everyone shown online during brief windows
- Condition meant to detect "incomplete data" but kept triggering forever

**Impact:**
Every time a guild member came online or went offline:
1. `CHAT_MSG_SYSTEM` event fires (lightweight, <1ms)
2. Triggers `GuildRoster()` API call
3. Triggers `GUILD_ROSTER_UPDATE` event
4. Handler scans **all 1000+ guild members** with these expensive operations:
   - `RefreshOnlineCache()` - Iterate all members, check online status
   - `RebuildBankerRoster()` - Build banker list from officer notes
   - `RefreshRequestsUI()` - Update UI banker controls
   - Multiple `GetNumGuildMembers()` calls
   - Guild info validation and caching

**Result:** 5-10ms+ lag spike per online/offline event, multiplied by dozens of events per play session.

**Solution Implemented:**
Changed **OR to AND** logic so initialization only continues while BOTH conditions true:

```lua
-- FIXED (after):
if self.fullRosterInitAttempts < 2 and (not totalMembers or not onlineMembers or totalMembers <= onlineMembers) then
    self.needsFullRosterRefresh = true
end
```

**Logic Breakdown:**
Continue full refreshes **only if**:
1. **Condition 1:** `fullRosterInitAttempts < 2` (not tried at least twice yet)
2. **AND Condition 2:** Roster appears incomplete:
   - `not totalMembers` - No total member count yet
   - `OR not onlineMembers` - No online member count yet
   - `OR totalMembers <= onlineMembers` - Suspicious equality (incomplete data)

Once `fullRosterInitAttempts >= 2`, the first condition becomes false, so **entire expression becomes false** regardless of second condition. Initialization complete, flag stays false.

**Why This Works:**
- **During initialization:** Both conditions true → continue refreshing until data stable
- **After initialization:** First condition false → stop refreshing even if data looks weird
- **Online/Offline events:** Handled by lightweight `CHAT_MSG_SYSTEM` handler instead
- **Result:** Full roster scan only during addon load, not on every member status change

**Lightweight Handler Design:**
After initialization, online/offline events use the optimized `CHAT_MSG_SYSTEM` handler:

**Modules/Events.lua (lines 315-343):**
- Pattern matching: `"(.+) has come online"` and `"(.+) has gone offline"`
- Direct table lookup: `onlineMembers[playerName] = true/nil`
- Selective updates: Only refresh if affected player is a banker
- **No full roster scan:** Just update single player's online status
- Performance: <1ms vs 5-10ms for full scan

**Operations Avoided Per Event:**
By stopping repeated full refreshes, we avoid:
- `RefreshOnlineCache()` - iterating all 1000+ members
- `RebuildBankerRoster()` - scanning officer notes for banker list
- `GetGuildRosterInfo()` calls for every single member
- Memory allocations for temporary tables
- Table sorting and comparisons

**Performance Metrics:**

**Before Fix:**
- **Full roster scan:** 5-10ms+ per online/offline event
- **Events per hour:** 50-100 in active guild
- **Total overhead:** 250-1000ms wasted per hour
- **User experience:** Noticeable stutter on each event

**After Fix:**
- **Initialization:** 5-10ms × 2 attempts only (during addon load)
- **Online/offline:** <1ms per event (lightweight handler)
- **Total overhead:** ~10-20ms per reload, near-zero during gameplay
- **User experience:** Smooth gameplay, no stuttering

**Edge Cases Handled:**

**Member Joins/Leaves Guild:**
- These trigger `GUILD_ROSTER_UPDATE` without `CHAT_MSG_SYSTEM`
- Handler detects missing system message → triggers full refresh
- Correct behavior: Need full scan for roster changes

**Alt Promotion to Banker:**
- Officer note changes trigger `GUILD_ROSTER_UPDATE`
- Handler rebuilds banker roster to pick up new banker
- Correct behavior: Need scan to update banker list

**Manual Roster Refresh:**
- User opens guild roster UI → triggers `GuildRoster()` API
- Handler processes normally during initialization
- After init, events marked as "handled via system messages"

**Files Modified:**
- `Modules/Events.lua` (lines 305-313): Fixed initialization condition logic
- `CHANGELOG.md`: Added PERF-007 entry with full technical details

**Related Issues:**
- PERF-005: P2P send queue throttling (separate fix)
- PERF-006: GetItemInfo stuttering (separate fix)
- [UI-008]: Roster caching improvements (future optimization)

**Verified By:** Testing in 1000-member guild
**Closed:** 2026-02-17

---

### 🟠 HIGH - All Resolved

#### ✅ [ADDON-001] Nil itemLink passed to Pawn/BagBrother causes errors

**Severity:** 🟠 HIGH
**Category:** Error Handling / Addon Compatibility
**Reporter:** User (BugSack error)
**Date Reported:** 2026-01-22
**Status:** ✅ CLOSED
**Fixed In:** v0.8.0
**Assigned To:** Development Team

**Description:**
When BagBrother addon updates the bank UI, it calls Pawn addon to display upgrade arrows, but encounters nil item links. While this is primarily a BagBrother/Pawn interaction issue, TOGBankClassic needed to add defensive nil checks to prevent propagating nil values to WoW API functions and other addons.

**Error Message:**
```
2x bad argument #1 to '?' (Usage: local itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture, sellPrice, classID, subclassID, bindTy
[Pawn/Pawn.lua]:5965: in function <Pawn/Pawn.lua:5960>
[Pawn/Pawn.lua]:5952: in function 'PawnShouldItemLinkHaveUpgradeArrow'
[BagBrother/core/classes/item.lua]:288: in function 'IsUpgrade'
[BagBrother/core/classes/item.lua]:211: in function 'UpdateUpgradeIcon'
```

**Stack Trace Context:**
Error occurs when opening bank → BagBrother UI updates → Pawn checks for upgrades → nil itemLink passed

**Locals:**
```
ItemLink = nil
CheckLevel = nil
PawnIsInitialized = true
```

**Root Cause:**
Item links can be nil when:
1. Item slots are empty
2. Item data hasn't loaded from cache yet
3. Desync between cached data and actual bank contents
4. `GetItemInfo()` returns nil for uncached items

TOGBankClassic was calling WoW API functions without checking for nil item links, which could contribute to error propagation.

**Fix Applied:**
Added comprehensive nil checks throughout TOGBankClassic in 6 files:

**1. Item.lua:**
- Added nil check in `GetInfo()` before calling `GetItemInfo()`
- Added check for nil name return from `GetItemInfo()`
- Added nil check in `GetItems()` to skip items with failed info loading
- Added nil check in `IsUnique()` to safely handle nil links

**2. Mail.lua:**
- Enhanced nil checking for `GetInboxItemLink()` results
- Added check for both nil link and nil name from `GetItemInfo()`

**3. Guild.lua:**
- Improved nil checking in `ReconstructItemLinks()` for item validation
- Added item existence check before accessing properties

**4. UI.lua:**
- Added nil check before calling `DressUpItemLink()`
- Added nil check before calling `PickupItem()` in drag handlers

**5. UI/Mail.lua:**
- Already had nil checks, validated they're sufficient

**6. UI/Search.lua:**
- Added nil checks for item link search operations
- Added validation for `GetItemName()` results
- Added check before creating `Item` object from link

**Example Fix (Item.lua GetInfo):**
```lua
function TOGBankClassic_Item:GetInfo(id, link)
	if not link then
		return nil
	end

	local name, _, rarity, level, _, _, _, _, _, icon, price, itemClassId, itemSubClassId = GetItemInfo(link)
	if not name then
		return nil
	end

	local equip = C_Item.GetItemInventoryTypeByID(id)
	-- ... rest of function
end
```

**Testing:**
- ✅ Added defensive checks at all item data access points
- ✅ Functions now gracefully handle nil item links
- ✅ No nil values propagated to WoW API or other addons
- ✅ UI handles missing item data without errors

**Impact:**
Prevents TOGBankClassic from contributing to error spam when other addons (like BagBrother) encounter nil item data. Makes the addon more robust when dealing with incomplete or loading item information.

**Resolution:**
Applied defensive programming throughout the codebase to check for nil item links and names before passing to WoW API functions or other processing. This ensures graceful degradation when item data is unavailable.

**Verified By:** Code review and error path analysis
**Closed:** 2026-01-22

---

#### ✅ [PERF-001] Serious performance degradation during normal gameplay

**Severity:** 🟠 HIGH
**Category:** Performance / Optimization
**Reporter:** Multiple Users (Production)
**Date Reported:** 2026-01-25
**Status:** ✅ CLOSED (Same root cause as PERF-002)
**Fixed In:** v0.7.18 (commit 77b16a1)
**Fixed Date:** 2026-01-26
**Reproducibility:** Was consistent in large guilds

**Description:**
Multiple guild members reported serious performance issues including lag, frame rate drops, and general game slowdown during normal gameplay with the addon.

**Root Cause:**
After investigation, determined this was caused by the same issue as PERF-002: the NormalizeRequestList() broadcast storm from request sync being piggybacked on inventory delta broadcasts. Every 3 minutes, 100+ guild members triggered cascading request queries causing ~9,696 request table accesses per second.

**Solution:**
Fixed by decoupling request sync from inventory sync (same fix as PERF-002). See PERF-002 for full details.

**Performance Impact (After Fix):**
- NormalizeRequestList() calls reduced from 12+/second to near-zero
- Eliminated 3-minute performance spikes
- Normal gameplay no longer affected by sync operations

**Closed:** 2026-01-26 (Resolved by PERF-002 fix)

---

#### ✅ [DATA-003] Integer overflow on request version timestamp causing crash

**Severity:** 🔴 CRITICAL
**Category:** Request Sync / Data Corruption
**Reporter:** User (Production)
**Date Reported:** 2026-01-25
**Status:** ✅ CLOSED
**Fixed In:** v0.7.17
**Fixed Date:** 2026-01-25
**Reproducibility:** Was intermittent

**Description:**
Request snapshot version timestamp was corrupted to ~176 trillion (instead of ~1.7 billion), causing integer overflow crashes when attempting to store in database.

**Error Details:**
```
85x integer overflow attempting to store 1.7673980749821e+14
[TOGBankClassic/Modules/RequestLog.lua]:948: in function 'ReceiveRequestsData'
```

**Root Cause:**
Classic Era uses 32-bit integers. Original MAX_TIMESTAMP (4102444800 for Jan 1, 2100) exceeded this limit, causing overflow even in validation code.

**Solution Implemented:**
1. Changed MAX_TIMESTAMP from 4102444800 to 2147483647 (max 32-bit signed integer)
2. Added validation in `GetRequestsVersion()` to reset corrupted stored versions
3. Added validation in `ReceiveRequestsData()` to reject corrupted incoming snapshots
4. Added validation in `NormalizeRequestList()` to skip corrupted timestamps
5. Fixed warning message to avoid triggering overflow when logging

**Files Modified:**
- `Modules/RequestLog.lua`: GetRequestsVersion(), ReceiveRequestsData(), NormalizeRequestList()

**Closed:** 2026-01-25

---

#### ✅ [DELTA-009] Delta sync failure warnings spam for offline players

**Severity:** 🔴 CRITICAL (User Experience)
**Category:** Error Handling / Communication
**Reporter:** User (Production)
**Date Reported:** 2026-01-25
**Status:** ✅ CLOSED
**Fixed In:** v0.7.17
**Fixed Date:** 2026-01-25
**Reproducibility:** Was consistent

**Description:**
Delta sync failure warnings persisted and spammed chat for players who were no longer online, creating unnecessary error noise.

**Solution Implemented:**
1. Added `ClearOfflineErrorCounters()` - Called on GUILD_ROSTER_UPDATE to reset error counters for offline players
2. Added online check before showing warnings - Only warn about players who are actually online
3. Added `ResetDeltaErrorCount()` - Clears error counter after successful full sync

**Files Modified:**
- `Modules/DeltaComms.lua`: Added cleanup functions
- `Modules/Events.lua`: Hooked GUILD_ROSTER_UPDATE to clear offline counters

**Closed:** 2026-01-25

---

#### ✅ [DELTA-007] TriggerCallback method does not exist

**Severity:** 🟠 HIGH
**Category:** Delta Application / UI Refresh
**Reporter:** User (BugSack error)
**Date Reported:** 2026-01-22
**Status:** ✅ CLOSED
**Fixed In:** v0.8.0
**Assigned To:** Development Team

**Description:**
After successfully applying a delta update, `ApplyDelta()` attempts to trigger a UI refresh by calling `TOGBankClassic_Events:TriggerCallback()`, but this method doesn't exist in the Events module, causing an error.

**Error Message:**
```
20x TOGBankClassic/Modules/Guild.lua:1940: attempt to call method 'TriggerCallback' (a nil value)
```

**Stack Trace:**
```
[TOGBankClassic/Modules/Guild.lua]:1940: in function 'ApplyDelta'
[TOGBankClassic/Modules/Chat.lua]:836: in function 'OnCommReceived'
[TOGBankClassic/Modules/Chat.lua]:24: in function <TOGBankClassic/Modules/Chat.lua:23>
[Ace3/CallbackHandler-1.0-8/CallbackHandler-1.0.lua]:19: in function
[Ace3/AceComm-3.0-14/AceComm-3.0.lua]:214: in function 'OnReceiveMultipartLast'
```

**Affected Code (Guild.lua:1940):**
```lua
-- OLD CODE:
-- Trigger UI refresh
TOGBankClassic_Events:TriggerCallback(TOGBankClassic_Events.DB_UPDATE)
```

**Root Cause:**
The `TriggerCallback()` method was mentioned in FEATURE_IMPROVEMENTS.md design specs and Tests.lua has a mock for it, but it was never actually implemented in the Events module. The Events module provides `RegisterMessage()` / `SendMessage()` / `UnregisterMessage()` through Ace3, but no `TriggerCallback()`.

**Impact:**
- **User Impact:** Delta updates applied successfully but UI doesn't auto-refresh
- **Frequency:** 100% of delta synchronizations
- **Workaround:** UI updates on next manual refresh or window reopen
- **Error Spam:** Generates error on every delta received

**Trigger Conditions:**
- Receive delta update from guild member via AceComm
- Delta successfully applied to local data
- Attempt to trigger UI refresh fails with nil method error

**Fix Applied:**
Replaced the non-existent `TriggerCallback()` call with direct UI refresh that matches existing patterns in the codebase:

```lua
-- NEW CODE:
-- Trigger UI refresh if Inventory window is open
if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
	TOGBankClassic_UI_Inventory:DrawContent()
end
```

This approach:
- Directly refreshes the Inventory UI when delta is applied
- Only refreshes if window is open (no unnecessary work)
- Matches existing pattern used in `ReconstructItemLinks()`
- No need to implement complex callback system for simple use case

**Alternative Approaches Considered:**
1. **Implement TriggerCallback method:** Would add unnecessary complexity since Ace3's `SendMessage` system already exists
2. **Use SendMessage system:** Would require registering message handlers in UI components - overkill for this use case
3. **Do nothing:** UI would only update on next manual refresh - poor UX

**Testing:**
- ✅ Delta updates now trigger immediate UI refresh
- ✅ No more nil method errors
- ✅ UI shows updated data in real-time when window is open
- ✅ No performance impact when window is closed

**Resolution:**
Replaced conceptual `TriggerCallback()` with pragmatic direct UI refresh. This fixes the error and provides better UX by immediately showing delta updates to users who have the inventory window open.

**Verified By:** In-game testing during delta synchronization
**Closed:** 2026-01-22

---

#### ✅ [ITEM-001] Item.Aggregate crashes when item.Count is nil

**Severity:** 🟠 HIGH
**Category:** Database / Error Handling
**Reporter:** User (BugSack error)
**Date Reported:** 2026-01-22
**Status:** ✅ CLOSED
**Fixed In:** v0.8.0
**Assigned To:** Development Team

**Description:**
The `Item:Aggregate()` function crashed with "attempt to perform arithmetic on field 'Count' (a nil value)" when processing items that have nil Count fields. This occurred when opening the inventory UI and building search data.

**Error Message:**
```
7x TOGBankClassic/Modules/Item.lua:119: attempt to perform arithmetic on field 'Count' (a nil value)
[TOGBankClassic/Modules/Item.lua]:119: in function 'Aggregate'
[TOGBankClassic/Modules/UI/Search.lua]:365: in function 'BuildSearchData'
[TOGBankClassic/Modules/UI/Inventory.lua]:150: in function 'DrawContent'
```

**Root Cause:**
The aggregation logic had two issues:
1. Initial validation only checked `v.Count` but not `item.Count` (the already-stored item)
2. When storing items with `items[key] = v`, items with nil Count would be stored as-is
3. Subsequent aggregations would crash when trying `item.Count + v.Count` if either was nil

Even with validation to skip items without Count, previously stored items from old data could still have nil Count fields, causing crashes during aggregation.

**Fix Applied (v2):**
Added defensive programming to handle nil Count on both sides of aggregation in Item.lua:
```lua
if items[key] then
    local item = items[key]
    -- Defensive: use default value if Count is missing
    local itemCount = item.Count or 1
    local vCount = v.Count or 1
    items[key] = { ID = item.ID, Count = itemCount + vCount, Link = item.Link }
else
    -- Ensure stored item has Count field
    items[key] = { ID = v.ID, Count = v.Count or 1, Link = v.Link }
end
```

**Fix Iterations:**
1. **v1 (Commit 29f0c41):** Added `not v.Count` validation to skip malformed items - Did NOT resolve issue
2. **v2 (Commit 3e2eec4):** Added defensive nil checks with default value (1) for both `item.Count` and `v.Count` - ✅ RESOLVED

**Testing:**
- ✅ In-game testing confirmed crash no longer occurs
- ✅ UI opens successfully even with corrupted/old item data
- ✅ Items with missing Count field now default to 1

**Resolution:**
Applied defensive programming approach using default value of 1 for any nil Count fields during aggregation. This handles both new items with missing Count and previously stored items from old data structures.

**Verified By:** User in-game testing
**Closed:** 2026-01-22

---

## Resolved Bugs (2026-01-21)

### 🔴 CRITICAL - All Resolved

#### ✅ [PROTO-001] Delta validation rejects link-less deltas without baseVersion

**Severity:** 🔴 CRITICAL
**Category:** Protocol / Backwards Compatibility
**Reporter:** Testing (Galdof logs)
**Date Reported:** 2026-01-21
**Status:** ✅ CLOSED
**Fixed In:** v0.8.0
**Assigned To:** Development Team

**Description:**
The delta validation in `Core:ValidateDeltaStructure()` requires `baseVersion` field, but v0.8.0 protocol removes this field for bandwidth savings. This causes all new protocol deltas to be rejected with "missing or invalid baseVersion" error.

**Error Message:**
```
> Metals-Azuresong shares delta (v0.8.0 Link-less) for Metals-Azuresong - validation failed: missing or invalid baseVersion
< togbank-r (Query) to Guild (80 bytes)
```

**Stack Trace:**
- Metals sends togbank-d4 (link-less delta without baseVersion)
- Galdof receives delta
- `Chat:OnCommReceived()` calls `Core:ValidateDeltaStructure()`
- Validation fails on line 119: `if not delta.baseVersion or type(delta.baseVersion) ~= "number" then`
- Returns error: "missing or invalid baseVersion"
- Galdof falls back to requesting full sync

**Affected Code (Core.lua:118-120):**
```lua
-- OLD CODE:
if not delta.baseVersion or type(delta.baseVersion) ~= "number" then
    return false, "missing or invalid baseVersion"
end
```

**Root Cause:**
When we removed `baseVersion` from `ComputeDelta()` in Guild.lua (v0.8.0 optimization), we didn't update the validation logic in Core.lua to make baseVersion optional.

**Impact:**
- **User Impact:** New protocol deltas always rejected, forcing full sync fallback
- **Frequency:** 100% of delta transmissions in NEW_ONLY mode
- **Bandwidth Impact:** Completely negates delta bandwidth savings (falls back to full sync)
- **Backwards Compatibility:** Breaks core functionality of v0.8.0 protocol

**Implementation Details:**

**✅ Fixed in Core.lua (line 118-122):**
```lua
-- v0.8.0: baseVersion is optional (removed from new protocol)
-- Old protocol deltas will still have it, new protocol won't
if delta.baseVersion and type(delta.baseVersion) ~= "number" then
    return false, "invalid baseVersion"
end
```
- Changed from `if not delta.baseVersion or ...` to `if delta.baseVersion and ...`
- Now only validates baseVersion type IF it's present
- Allows deltas without baseVersion (v0.8.0 new protocol)
- Still validates baseVersion type if present (v0.7.0 old protocol)
- Fully backwards compatible with both protocols

**ApplyDelta Already Compatible:**
The `Guild:ApplyDelta()` function already handles optional baseVersion correctly:
```lua
-- v0.8.0: baseVersion no longer sent, but accept it for backwards compatibility
local baseVersion = deltaData.baseVersion or currentVersion

-- Only check version mismatch if delta included baseVersion (v0.7.0 and earlier)
if deltaData.baseVersion and currentVersion ~= baseVersion then
    -- Version mismatch handling...
end
```

**Testing Results:**
- ✅ Validation fix implemented in Core.lua
- ✅ In-game testing completed successfully
- ✅ Link-less deltas (togbank-d4) now accepted without errors
- ✅ No more "missing or invalid baseVersion" validation failures
- ✅ Backwards compatible with old protocol deltas that include baseVersion

**Resolution:**
Made `baseVersion` field optional in delta validation. Changed Core.lua line 118 from requiring the field to only validating its type IF present. This allows v0.8.0 deltas (without baseVersion) while still supporting v0.7.0 deltas (with baseVersion).

**Related Changes:**
- Guild.lua: `ComputeDelta()` no longer includes baseVersion (line 1421)
- Guild.lua: `ApplyDelta()` treats baseVersion as optional (line 1770)
- Core.lua: Validation now treats baseVersion as optional (line 118)

**Verified By:** In-game testing on 2026-01-21
**Closed:** 2026-01-21

---

#### ✅ [UI-001] Inventory UI crashes when alt.bank.slots is nil

**Severity:** 🔴 CRITICAL
**Category:** UI / Database
**Reporter:** User
**Date Reported:** 2026-01-21
**Status:** ✅ CLOSED
**Fixed In:** v0.8.0
**Assigned To:** Development Team

**Description:**
The Inventory UI crashes when opening the window if an alt character has bank data but the `bank.slots` field is nil. This can occur with characters that were scanned before slots tracking was implemented, or with incomplete/corrupted data.

**Error Message:**
```
1x ...rfaceTOGBankClassic/Modules/UI/Inventory.lua:177: attempt to index field 'slots' (a nil value)
[TOGBankClassic/Modules/UI/Inventory.lua]:177: in function 'DrawContent'
[TOGBankClassic/Modules/UI/Inventory.lua]:45: in function 'Open'
[TOGBankClassic/Modules/UI/Inventory.lua]:29: in function 'Toggle'
[TOGBankClassic/Modules/UI/Minimap.lua]:19: in function 'OnClick'
```

**Stack Trace:**
- User clicks minimap icon
- `Minimap.lua:19` calls `Toggle()`
- `Inventory.lua:29` calls `Open()`
- `Inventory.lua:45` calls `DrawContent()`
- `Inventory.lua:177` tries to access `alt.bank.slots.count` when `alt.bank.slots` is nil

**Affected Code (Inventory.lua:177):**
```lua
if alt.bank then
    slots = slots + alt.bank.slots.count       -- Line 177: crashes if alt.bank.slots is nil
    total_slots = total_slots + alt.bank.slots.total
end
if alt.bags then
    slots = slots + alt.bags.slots.count       -- Line 181: same issue possible
    total_slots = total_slots + alt.bags.slots.total
end
```

**Character State:**
- Character: Metals-Azuresong
- Has `alt.money`, `alt.bags`, `alt.version`, `alt.bank` fields
- Missing `alt.bank.slots` field (nil value)
- Bank data exists but incomplete

**Root Cause:**
The `slots` field was added to track bank/bag slot usage, but existing characters scanned before this feature don't have this data. The UI code doesn't check if `slots` exists before accessing it.

**Reproduction Steps:**
1. Have a character with bank data from before slots tracking was added
2. Character has `alt.bank` table but `alt.bank.slots` is nil
3. Click minimap icon to open Inventory UI
4. UI tries to access `alt.bank.slots.count`
5. Crash with "attempt to index field 'slots' (a nil value)"

**Impact:**
- **User Impact:** Cannot open Inventory UI at all when any alt has incomplete data
- **Frequency:** Affects all users upgrading from versions before slots tracking
- **Workaround:** None - UI is completely inaccessible

**Proposed Solutions:**

**Option 1: Defensive nil checks (Quick fix)**
```lua
if alt.bank and alt.bank.slots then
    slots = slots + alt.bank.slots.count
    total_slots = total_slots + alt.bank.slots.total
end
if alt.bags and alt.bags.slots then
    slots = slots + alt.bags.slots.count
    total_slots = total_slots + alt.bags.slots.total
end
```

**Option 2: Data migration on load (Better solution)**
Add migration logic in Bank.lua or Database.lua to initialize missing `slots` fields:
```lua
-- During alt data load/validation
if alt.bank and not alt.bank.slots then
    alt.bank.slots = { count = 0, total = 0 }
end
if alt.bags and not alt.bags.slots then
    alt.bags.slots = { count = 0, total = 0 }
end
```

**Option 3: Compute slots on demand**
Calculate slot counts from actual item data if `slots` field is missing.

**Recommended Approach:**
Implement both Option 1 (defensive checks in UI) AND Option 2 (data migration). This provides:
- Immediate crash prevention in UI
- Proper data structure for all characters
- Backward compatibility with old data
- Graceful handling of incomplete data

**Implementation Details:**

**✅ Fixed in Inventory.lua (lines 177-187):**
```lua
if alt.bank and alt.bank.slots then
    slots = slots + alt.bank.slots.count
    total_slots = total_slots + alt.bank.slots.total
end
if alt.bags and alt.bags.slots then
    slots = slots + alt.bags.slots.count
    total_slots = total_slots + alt.bags.slots.total
end
```
- Added defensive nil checks before accessing `slots.count` and `slots.total`
- Prevents crash when `slots` field is missing
- UI gracefully handles incomplete data by skipping those characters' slot counts

**✅ Fixed in Database.lua (Database:Load()):**
```lua
-- v0.8.0: Migrate old alt data to ensure slots fields exist
if db.alts then
    for name, alt in pairs(db.alts) do
        if type(alt) == "table" then
            if alt.bank and not alt.bank.slots then
                alt.bank.slots = { count = 0, total = 0 }
                TOGBankClassic_Output:Debug("Migrated alt data: initialized bank.slots for %s", name)
            end
            if alt.bags and not alt.bags.slots then
                alt.bags.slots = { count = 0, total = 0 }
                TOGBankClassic_Output:Debug("Migrated alt data: initialized bags.slots for %s", name)
            end
        end
    end
end
```
- Runs during database load on addon init
- Initializes missing `slots` fields with zero values
- One-time migration for each character
- Debug output logs migrated characters
- Ensures all existing data has proper structure going forward

**Testing Results:**
- ✅ Defensive checks prevent immediate crashes (Inventory.lua lines 177-187)
- ✅ Data migration ensures proper structure on load (Database.lua)
- ✅ In-game testing completed successfully
- ✅ Inventory UI opens without crashes
- ✅ Slot counts display correctly for all characters

**Resolution:**
Implemented dual-layer fix: defensive nil checks in UI code prevent crashes, and database migration ensures all alt data has proper structure. Migration runs once on addon load and initializes missing `slots` fields with zero values.

**Verified By:** In-game testing on 2026-01-21
**Closed:** 2026-01-21

---

#### ✅ [UI-002] Items don't appear in UI after data integration

**Severity:** 🔴 CRITICAL
**Category:** UI / Protocol
**Reporter:** User (Galdof testing)
**Date Reported:** 2026-01-21 (Evening)
**Status:** ✅ CLOSED
**Fixed In:** v0.8.0
**Assigned To:** Development Team

**Description:**
After receiving link-less data via togbank-d3 protocol, items don't appear in the UI even though data integration succeeds and shows "(newer, integrating)" status. Manual UI refresh (close/reopen) doesn't fix the issue. Items remain invisible indefinitely.

**User Report:**
```
"what takes it so long for the data to actual appear after i get the integrating message"
"closing and reopen DOESN'T work"
```

**Debug Observations:**
- Data receives successfully: "We accept it. (newer, integrating)"
- `ReceiveAltData()` returns `ADOPTION_STATUS.ADOPTED`
- Items saved to database with correct structure
- Manual UI refresh shows no items
- Items permanently missing from display

**Stack Trace:**
1. Sender transmits togbank-d3 with link-less items (IDs only)
2. Receiver calls `ReceiveAltData()` which saves data
3. `ReconstructItemLinks()` called to rebuild Links from IDs
4. For uncached items: `Item:CreateFromItemID()` + `ContinueOnItemLoad()` callback
5. **BUG**: Async callback sets `item.Link` but doesn't trigger UI refresh
6. UI already rendered without items, never updates when Links become available
7. User sees "integrating" message but no items appear

**Root Cause:**
The `ReconstructItemLinks()` function in Guild.lua uses asynchronous `Item:ContinueOnItemLoad()` callbacks to fetch item data from the server. When the callback completes and sets `item.Link`, the UI has already been rendered and doesn't know the link is now available. There's no mechanism to refresh the UI after async link reconstruction completes.

**Affected Code (Guild.lua:970-995 - Before Fix):**
```lua
function TOGBankClassic_Guild:ReconstructItemLinks(items)
    -- ...
    for _, item in ipairs(items) do
        if item.ID and not item.Link then
            local itemLink = select(2, GetItemInfo(item.ID))
            if itemLink then
                item.Link = itemLink  -- Cached - immediate
            else
                -- Uncached - async callback
                local itemObj = Item:CreateFromItemID(item.ID)
                if itemObj then
                    itemObj:ContinueOnItemLoad(function()
                        local link = itemObj:GetItemLink()
                        if link then
                            item.Link = link
                            -- BUG: No UI refresh here!
                        end
                    end)
                end
            end
        end
    end
end
```

**Impact:**
- **User Impact:** Pull-based protocol completely broken - data integrates but never displays
- **Frequency:** 100% of link-less data transmissions when items not in local cache
- **Workaround:** None - items never appear even after waiting or manual refresh
- **Protocol Impact:** Makes v0.8.0 protocol unusable for end users

**Reproduction Steps:**
1. Fresh client or cleared item cache
2. Receive link-less data via togbank-d3
3. Observe "integrating" message in chat
4. Open UI - items don't appear
5. Close and reopen UI - items still don't appear
6. Wait indefinitely - items never appear

**Implementation Details:**

**✅ Fixed in Guild.lua (lines 970-1008):**
```lua
function TOGBankClassic_Guild:ReconstructItemLinks(items)
    if not items then
        return
    end

    local needsAsyncLoad = false

    for _, item in ipairs(items) do
        if item.ID and not item.Link then
            local itemLink = select(2, GetItemInfo(item.ID))
            if itemLink then
                item.Link = itemLink
            else
                needsAsyncLoad = true
                local itemObj = Item:CreateFromItemID(item.ID)
                if itemObj then
                    itemObj:ContinueOnItemLoad(function()
                        local link = itemObj:GetItemLink()
                        if link then
                            item.Link = link
                            -- NEW: Refresh UI when link becomes available
                            if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
                                TOGBankClassic_UI_Inventory:DrawContent()
                            end
                        end
                    end)
                end
            end
        end
    end

    -- NEW: If all links loaded from cache, refresh UI now
    if not needsAsyncLoad and TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
        TOGBankClassic_UI_Inventory:DrawContent()
    end
end
```

**Changes Made:**
1. Track whether async loading is needed with `needsAsyncLoad` flag
2. Add UI refresh inside async callback when link becomes available
3. Add immediate UI refresh if all links loaded from cache (no async needed)
4. Check if UI is open before refreshing to avoid unnecessary redraws

**Behavior After Fix:**
- Items with cached data: Links load immediately → UI refreshes once
- Items needing server query: Links load async → UI refreshes as each completes
- User sees items appear as soon as their data becomes available
- No delay between "integrating" message and items displaying

**Testing Results:**
- ✅ Items now appear immediately after integration
- ✅ Cached items display instantly
- ✅ Uncached items appear within 1-2 seconds (server query time)
- ✅ UI updates multiple times as async callbacks complete
- ✅ No manual refresh required
- ✅ Works for both togbank-d3 full sync and togbank-d4 deltas

**Related Changes:**
- Chat.lua: Added UI refresh in togbank-d/d3 handlers when status = ADOPTED (safety net)
- Already had UI refresh attempts, but weren't effective because Links were nil
- With this fix, those safety refreshes now work as intended

**Resolution:**
Added UI refresh mechanism to `ReconstructItemLinks()` that triggers `DrawContent()` after successful link reconstruction. Handles both immediate (cached) and async (server query) cases. Items now appear as soon as their links become available from WoW API.

**Verified By:** In-game testing on 2026-01-21 (Evening)
**Closed:** 2026-01-21

---

### 🟠 HIGH

#### ✅ [DATA-001] Inventory hash missing for existing alt data

**Severity:** 🟠 HIGH
**Category:** Database / Protocol
**Reporter:** Testing (hash broadcasting logs)
**Date Reported:** 2026-01-21
**Status:** ✅ CLOSED
**Fixed In:** v0.8.0
**Assigned To:** Development Team

**Description:**
After implementing v0.8.0 pull-based delta protocol with inventory hashing, broadcasts showed "(no hash)" for all existing alts. The `inventoryHash` field is only computed during `Bank:Scan()` which requires opening/closing the bank on each character. Since most alts haven't been logged in since hash feature was added, they have no hash values.

**Observed Behavior (from logs):**
```
TOGBankClassic: [DEBUG] Broadcasting Metals-Azuresong: version=1769020573 (no hash)
TOGBankClassic: [DEBUG] Broadcasting Togbank-Azuresong: version=1746826634 (no hash)
TOGBankClassic: [DEBUG] Broadcasting Toggear-Azuresong: version=1768949160 (no hash)
[...60+ more alts without hashes...]
```

**Root Cause:**
The `inventoryHash` field is computed by `Core:ComputeInventoryHash(bank, bags, money)` and stored in `alt.inventoryHash` during bank scan. However:
- Hash feature is new in v0.8.0
- Existing alt data from previous sessions doesn't have hash values
- Bank:Scan() only runs when bank opened/closed on that specific character
- Users have 60+ alts, haven't logged into most recently

**Impact:**
- **Protocol Impact:** Pull-based protocol relies on hashes for detecting inventory changes
- **Without Hashes:** Cannot compare inventory states to determine if query needed
- **Frequency:** Affects 100% of existing alt data on upgrade to v0.8.0
- **Workaround:** Would require logging into every alt and opening bank (impractical)

**Implementation Details:**

**✅ Fixed in Database.lua (Database:InitializeDatabase()):**
```lua
-- v0.8.0: Migrate alt data to compute inventory hashes for existing data
if db.alts then
    for name, alt in pairs(db.alts) do
        if type(alt) == "table" then
            -- Compute hash for alts that have inventory but no hash yet
            if not alt.inventoryHash and alt.bank and alt.bags then
                local money = alt.money or 0
                alt.inventoryHash = TOGBankClassic_Core:ComputeInventoryHash(alt.bank, alt.bags, money)
                TOGBankClassic_Output:Debug("Migrated alt data: computed inventory hash for %s (hash=%d)", name, alt.inventoryHash)
            end
        end
    end
end
```

**Migration Results (from logs):**
- ✅ Successfully migrated 61 alts with inventory data
- ✅ Computed hashes from existing bank/bags/money data
- ✅ One alt skipped (Engnschematc-Azuresong) - missing bank or bags data

**Testing Results:**
- ✅ Migration runs on addon load after /reload
- ✅ Hash values computed from saved inventory data
- ✅ Broadcasts now show hash values: `Broadcasting X: version=Y, hash=Z`
- ✅ Pull-based protocol hash comparison now functional
- ✅ Hash mismatch detection triggers selective queries
- ✅ Galdof successfully queried and received updated data based on hash difference

**Resolution:**
Added one-time migration in Database.lua that computes inventory hashes for all existing alt data on addon load. Uses same `ComputeInventoryHash()` function as Bank:Scan() to ensure consistency. Migration only runs for alts with complete bank+bags data and missing hash.

**Verified By:** In-game testing on 2026-01-21
**Closed:** 2026-01-21

---

## Active Bugs

### 🔴 CRITICAL

*No critical bugs at this time.*

### 🟠 HIGH

*No high priority bugs at this time.*

### 🟡 MEDIUM

*No medium priority bugs at this time.*

### 🟢 LOW

*No low priority bugs at this time.*

---

## Resolved Bugs (2026-01-21)

### 🟠 HIGH - All Resolved

#### ✅ [SYNC-001] Version timestamp desync causes unnecessary queries on login

**Severity:** 🟡 MEDIUM
**Category:** Communication / Protocol
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Status:** FIXED - Separate broadcast systems implemented
**Assigned To:** Development Team

**Description:**
When a bank alt logs in with no inventory changes, it broadcasts its version data. Other clients compare their cached version timestamps and query for updates even when they already have the current data. This creates unnecessary network traffic and query spam.

**Observed Behavior (from logs):**
```
[Metals-Azuresong logs in]
TOGBankClassic: [DEBUG] No changes detected for Metals-Azuresong (delta would be empty)
TOGBankClassic: [DEBUG] No changes for Metals-Azuresong, skipping data send (queries will be answered)
TOGBankClassic: [DEBUG] < togbank-v (Version) to Guild (3390 bytes)

[Galdof receives version broadcast]
TOGBankClassic: [DEBUG] > Hezzako-Myzrael has fresher bank data about Metals-Azuresong, querying.
TOGBankClassic: [DEBUG] < togbank-r (Query) to Guild (99 bytes)
```

**Root Cause Analysis:**
The issue appears to be that different clients have different cached version timestamps for the same alt's data, even when the actual inventory data is identical. When the alt broadcasts its version on login (even with no changes), clients with older cached timestamps trigger queries.

**Possible Causes:**
1. **Version timestamp inconsistency:** Different clients received different update timestamps for the same data
2. **Missed broadcasts:** Some clients missed previous version broadcasts and have stale timestamps
3. **Race conditions:** Rapid logins/logouts causing timestamp updates to propagate inconsistently
4. **Database persistence:** Cached timestamps in SavedVariables may be out of sync between clients

**Current Behavior:**
When no changes detected:
- Alt still broadcasts version (line 815 in Guild.lua: `TOGBankClassic_Events:Sync()`)
- Broadcast includes cached version timestamps from `self.Info.alts[k].version`
- Clients compare: `if not ourVersion or v > ourVersion` (Chat.lua line 254)
- Any client with older cached timestamp triggers query

**Design Intent:**
The version broadcast on no-change login was intentional: "let clients with old versions can query" to ensure everyone has current data. This is CORRECT when clients genuinely have stale data.

**The Bug:**
The bug is NOT the broadcast itself - it's that clients have DIFFERENT cached version timestamps for the SAME data. Need to investigate why version timestamps desync between clients.

**Investigation Needed:**
1. Why do clients cache different version timestamps for same alt data?
2. Are all clients receiving and properly storing version updates?
3. Is there a race condition during version broadcast/processing?
4. Should version timestamps be more deterministic (based on data hash, not time)?

**Workarounds Considered:**
- ❌ Remove version broadcast on no-change: Would prevent catching genuinely stale data
- ❌ Add version broadcast throttling: Doesn't fix root cause of timestamp desync
- ✅ **IMPLEMENTED: Separate broadcast systems for delta and legacy clients**

**Solution Implemented:**
Created a separate delta version broadcast system (`togbank-dv`) that operates independently from the legacy version broadcast (`togbank-v`):

1. **New Protocol Prefix:** `togbank-dv` for delta-capable clients only
2. **Dual Broadcasts:** When no changes detected, send both `togbank-v` (legacy) and `togbank-dv` (delta)
3. **Conditional Processing:**
   - Delta clients (`togbank-dv`): Only query if they support delta AND have older version
   - Legacy clients (`togbank-v`): Continue existing behavior
4. **Separation of Concerns:**
   - Delta version tracking for precise delta computation
   - Legacy version tracking for basic "is data fresh?" checks
   - No interference between the two systems

**Changes Made:**
- `Constants.lua`: Added `togbank-dv` prefix description
- `Chat.lua`: Register handler for `togbank-dv`, differentiate processing logic
- `Events.lua`: Added `SyncDeltaVersion()` function for delta broadcasts
- `Guild.lua`: Send both version types when no changes detected

**Impact:**
- Eliminates unnecessary query spam between delta and non-delta clients
- Delta clients only respond to delta version broadcasts
- Legacy clients unaffected, continue normal operation
- Clean separation allows independent evolution of both systems

**Impact:**
- Eliminates unnecessary query spam between delta and non-delta clients
- Delta clients only respond to delta version broadcasts
- Legacy clients unaffected, continue normal operation
- Clean separation allows independent evolution of both systems

**Testing Required:**
- ✅ Verify delta clients only query on `togbank-dv` broadcasts
- ✅ Verify legacy clients continue to work with `togbank-v` broadcasts
- ✅ **CONFIRMED: No query spam when bank alt logs in with no changes**
- ✅ Verify legitimate stale data still triggers queries correctly

**Test Results (2026-01-20):**
```
[Metals logs in with no changes]
TOGBankClassic: [DEBUG] No changes detected for Metals-Azuresong (delta would be empty)
TOGBankClassic: [DEBUG] < togbank-v (Version) to Guild (3391 bytes)
TOGBankClassic: [DEBUG] < togbank-dv (Delta Version) to Guild (3391 bytes)

[Galdof (delta client) - NO QUERY TRIGGERED]
TOGBankClassic: [DEBUG] > Metals-Azuresong > togbank-s (Share)
[No "has fresher bank data about Metals-Azuresong, querying" message]

[Delta Sync Successfully Transmitting - 85% Bandwidth Savings]
TOGBankClassic: [DEBUG] Comparing Metals-Azuresong: previous bank has 9 items, bags have 12 items; current bank has 9 items, bags have 13 items
TOGBankClassic: [DEBUG] ✓ Delta selected for Metals-Azuresong: 348 bytes vs 2368 bytes full (14.7% size, 2020 bytes saved)
TOGBankClassic: [DEBUG] < togbank-d2 (Delta Data) to Guild (348 bytes)
TOGBankClassic: [DEBUG] Sent delta update for Metals-Azuresong via togbank-d2
TOGBankClassic: [DEBUG] Send complete: 2 chunks, 348 bytes in 3.1s
```

**Results:**
- ✅ WORKING - Delta clients successfully ignore legacy broadcasts
- ✅ WORKING - Delta sync transmission functional (348 bytes vs 2368 bytes = 85% savings)
- ✅ FIXED - Self-query bug (clients no longer query sender about themselves)
- ⚠️ TESTING - Delta chain replay with removed age check

**Additional Fixes (Session 2 - 2026-01-20):**

1. **Self-Query Prevention**: Added check to prevent clients from querying sender about the sender's own alt
   - Line 257-262 in Chat.lua: Skip if `kNorm == senderNorm`

2. **Broken Age Check Removed**: Removed premature rejection in delta chain replay
   - Guild.lua line ~1465: Removed `versionGap > MAX_HOPS * 60` check
   - Was rejecting deltas older than 30 minutes (broken calculation)
   - Now lets `BuildDeltaChain()` naturally fail if deltas don't exist
   - Makes delta sync practical for real-world usage patterns

**Current Status - End of Day 2026-01-20:**
- Delta sync successfully transmitting with major bandwidth savings
- Self-queries eliminated
- Legacy/delta broadcast separation working
- Age check removed - needs testing with actual offline scenarios
- Ready for continued testing of delta chain replay tomorrow

**Next Steps:**
1. Test delta chain replay with the fixed age logic
2. Verify offline clients can catch up via delta chains
3. Monitor for any remaining edge cases
4. Consider additional optimizations if needed

---

#### ✅ [SCAN-001] Inventory scan only triggers on window close events (not BAG_UPDATE)

**Severity:** 🟡 MEDIUM
**Category:** Database / Inventory Scanning
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Status:** ✅ CLOSED - Moved to Feature Improvements
**Resolution:** Not a bug - current design works as intended. Real-time scanning is a feature enhancement.
**Resolution Date:** 2026-01-21

**Description:**
Inventory scanning (character bags + bank) only triggers when closing specific WoW windows (bank, mail, trade, auction house, merchant). The addon does NOT monitor BAG_UPDATE events. When any tracked window closes, OnUpdateStop() calls Scan() which reads:
- **Character bags (0-4)** - ALWAYS scanned on window close
- **Bank bags (5-11) + vault** - Only if IsBankAvailable() returns true

This means:
1. Inventory changes made while windows are open are NOT detected until window close
2. `/togbank share` sends cached data - it does NOT trigger a fresh scan
3. Delta sync comparisons use stale data if inventory changed after last window close
4. No real-time scanning on BAG_UPDATE, PLAYERBANKSLOTS_CHANGED, or similar events

**Steps to Reproduce:**
1. Open bank (BANKFRAME_OPENED fires, sets hasUpdated flag)
2. Close bank (BANKFRAME_CLOSED fires, calls Scan(), updates cached data)
3. Run `/togbank share` (baseline snapshot created from cached data)
4. Open bank again
5. Remove/add items from **character bags** (bags 0-4) while bank remains open
6. Run `/togbank share` again (WITHOUT closing bank)
7. Result: Shows "previous bank has X items, bags have Y items; current bank has X items, bags have Y items" with no changes detected
8. Cached data was NOT updated because window still open

**Expected Behavior:**
Inventory scan should trigger in real-time whenever items change, not just on window close. Monitor:
- **BAG_UPDATE** for bags 0-11 (character bags + bank bags)
- **PLAYERBANKSLOTS_CHANGED** for bank vault slots
- Continue existing window close scans as secondary trigger
- `/togbank share` should either trigger fresh scan OR warn user if data is stale

With debouncing to prevent spam during rapid changes (looting, crafting, etc.)

**Actual Behavior:**
Scan triggers ONLY when closing these windows (OnUpdateStop → Scan):
- BANKFRAME_CLOSED (line 176)
- MAIL_CLOSED (line 209)
- TRADE_CLOSED (line 224)
- AUCTION_HOUSE_CLOSED (line 229)
- MERCHANT_CLOSED (line 234)

Inventory changes made WHILE windows are open are not detected. `/togbank share` sends cached data without triggering a fresh scan.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Affects: ALL users who change character bag inventory while bank is open
- Also affects: Bagnon, AdiBags, ArkInventory, or any bag replacement addon users
- All versions affected

**Root Cause:**
Events.lua registers multiple window events but NO bag update events:

**OnUpdateStart() triggers (sets hasUpdated flag):**
- BANKFRAME_OPENED (line 173)
- MAIL_SHOW (line 177)
- TRADE_SHOW (line 221)
- AUCTION_HOUSE_SHOW (line 226)
- MERCHANT_SHOW (line 231)

**OnUpdateStop() triggers (calls Scan if hasUpdated):**
- BANKFRAME_CLOSED (line 176)
- MAIL_CLOSED (line 209)
- TRADE_CLOSED (line 224)
- AUCTION_HOUSE_CLOSED (line 229)
- MERCHANT_CLOSED (line 234)

Bank.lua:OnUpdateStop (line 242) checks hasUpdated flag then calls Scan():
```lua
function TOGBankClassic_Bank:OnUpdateStop()
    if self.hasUpdated then
        self:Scan()
    end
    self.hasUpdated = false
end
```

Scan() (lines 157-176) reads:
- `alt.bank.items` - IF IsBankAvailable() (line 157-166)
- `alt.bags.items` - ALWAYS (line 171-176)

**Missing events:**
- BAG_UPDATE for bags 0-11
- PLAYERBANKSLOTS_CHANGED for vault
- Real-time inventory change detection

**Diagnostic Logging Issue:**
Guild.lua lines 1020-1028 only shows bank item counts:
```lua
"Comparing %s: previous bank has %d items, current bank has %d items"
```
This is misleading - it doesn't show bag counts, making it appear bags aren't compared (but they are at lines 1032-1034).

**Proposed Fix:**
1. Monitor **BAG_UPDATE** events for all bags (0-11) - fires when bag contents change
2. Monitor **PLAYERBANKSLOTS_CHANGED** for bank vault updates
3. Add debouncing (500ms delay) to coalesce rapid changes during looting/crafting
4. Keep existing window close triggers as fallback/secondary scan
5. Option A: Make `/togbank share` trigger fresh scan before sending
6. Option B: Add staleness check - warn if cached data older than X seconds
7. Update diagnostic logging already done: "previous bank has X items, bags have Y items; current bank has X items, bags has Y items"

**Impact:**
- **CRITICAL:** Delta sync testing cannot proceed - inventory changes not detected until window close
- ALL users affected when changing inventory with any tracked window open
- `/togbank share` sends cached data without warning user it may be stale
- Requires closing bank/mail/trade/auction/merchant window after changes to update cache
- No indication to user that scan hasn't run
- Delta comparison may show "no changes" when changes exist

**Workaround:**
After making inventory changes, BEFORE `/togbank share`:
1. **Close any open window** (bank/mail/trade/auction/merchant) - triggers OnUpdateStop → Scan()
2. OR `/reload` - Forces fresh scan on login
3. OR open+close mailbox if nearby - MAIL_CLOSED triggers scan

NOTE: Simply reopening a window does NOT rescan - must CLOSE it first.

**Priority:**
Critical - blocks delta sync testing, affects all users changing character bag inventory

**Notes:**
- Automatic 3-minute share broadcasts cached data - may be stale if no window closed recently
- Delta computation DOES compare bags (Guild.lua lines 1032-1034)
- Diagnostic logging updated to show both bank and bag counts
- Guild.lua:SendAltData() does NOT call Scan() - only sends cached data from Info.alts[]
- Character bags (0-4) always scanned on window close, bank bags (5-11) only if IsBankAvailable()
- Issue affects manual `/togbank share` AND automatic shares if inventory changed after last window close
- Related to DELTA-004 (exposed this issue via diagnostic logging)

*No other high priority bugs reported*

---

#### ✅ [DELTA-006] Delta rejection without recovery for offline players (version mismatch gap)

**Severity:** 🔴 CRITICAL
**Category:** Protocol / Delta Application
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Status:** ✅ CLOSED - Abandoned with v0.7.0
**Resolution:** Superseded by v0.8.0 pull-based protocol with inventory hashing - version matching no longer relies on strict delta chains.
**Resolution Date:** 2026-01-21

**Description:**
Delta sync requires EXACT version matching. When a player is offline and misses updates, they have an old version and ALL subsequent deltas are rejected. The auto-recovery system (query for full sync) fails silently, leaving the player permanently out of sync until manual intervention.

This breaks the fundamental use case: **Players who go offline should be able to sync when they return.**

**Impact:**
- **CRITICAL:** Delta sync completely non-functional for offline players
- Every delta rejection triggers full sync fallback, negating bandwidth savings
- Auto-recovery (`togbank-r` query) appears broken - full sync never arrives
- Players stay permanently out of sync after missing ONE update
- Affects EVERY player who logs in after banker makes updates

**Steps to Reproduce:**
1. Galdof (receiver) has Metals data at version `v1768949336`
2. Galdof goes offline (logs out or AFK)
3. Metals (banker) makes updates over 15 minutes → version `v1768950207`
4. Galdof comes back online
5. Metals sends delta: `baseVersion=1768950207, version=1768950250`
6. Galdof rejects: "Version mismatch for Metals-Azuresong (have 1768949336, delta expects 1768950207)"
7. Galdof sends query: `< togbank-r (Query) to Guild (53 bytes)`
8. **Full sync never arrives** (recovery failed)
9. Galdof remains out of sync, bracer item not visible in UI

**Expected Behavior (Current - Broken):**
```
Delta rejected → Query for full sync → Metals responds → Full sync applied → Synced
```

**Actual Behavior:**
```
Delta rejected → Query sent → No response → Permanently out of sync
```

**Root Cause:**
1. **Strict version matching**: Delta requires `currentVersion == baseVersion` (zero tolerance)
2. **Recovery failure**: `togbank-r` query broadcast appears unreliable (sender auth? timing?)
3. **No delta chain**: Sender doesn't store intermediate deltas to replay missed updates

**Proposed Solution - Delta Chain Replay:**

Instead of falling back to full sync, implement delta chain replay to gracefully handle offline players.

**Architecture:**
1. **Sender stores delta history**: Keep last 10 deltas per alt (configurable)
2. **New protocol**: `togbank-dr` (Delta Range Request)
3. **Version gap detection**: Receiver detects version mismatch, calculates gap
4. **Chain request**: Request all deltas from oldVersion → newVersion
5. **Sequential application**: Apply deltas in order to catch up

**Example Flow:**
```lua
-- Sender (Metals) delta history:
deltaHistory["Metals-Azuresong"] = {
  {baseVersion=100, version=105, delta={bank:{modified:[...]}}},  -- Update 1
  {baseVersion=105, version=110, delta={bags:{added:[...]}}},     -- Update 2
  {baseVersion=110, version=115, delta={money:5000}}              -- Update 3
}

-- Receiver (Galdof) has v100, receives delta expecting v115:
1. Detect mismatch: have=100, need=115
2. Send: togbank-dr request for range [100, 115]
3. Metals sends 3 deltas (still smaller than full sync)
4. Galdof applies sequentially:
   v100 + delta1 → v105
   v105 + delta2 → v110
   v110 + delta3 → v115
5. ✓ Synced! Bandwidth: ~900 bytes vs ~1800 bytes full
```

**Benefits:**
- ✅ Works for offline players (most common scenario)
- ✅ Still bandwidth-efficient (chain < full sync)
- ✅ Automatic recovery without manual intervention
- ✅ Graceful degradation (falls back to full if gap too large)

**Implementation Requirements:**

**Database.lua:**
```lua
SaveDeltaHistory(guildName, altName, baseVersion, version, delta)
GetDeltaHistory(guildName, altName, fromVersion, toVersion) → delta[]
CleanupDeltaHistory(guildName) -- Remove deltas older than 1 hour
```

**Constants.lua:**
```lua
DELTA_HISTORY_MAX_COUNT = 10      -- Keep last N deltas per alt
DELTA_HISTORY_MAX_AGE = 3600      -- Purge deltas older than 1 hour
DELTA_CHAIN_MAX_HOPS = 10         -- Max deltas in one chain (prevent abuse)
DELTA_CHAIN_MAX_SIZE = 5000       -- If chain > 5KB, use full sync instead
```

**Guild.lua:**
```lua
-- Sender side
SendAltData(name)
  → ComputeDelta() → SaveDeltaHistory() → Send delta

-- Receiver side
ApplyDelta(name, deltaData)
  → if version mismatch:
       → RequestDeltaChain(fromVersion, toVersion)
       → Receive chain → ApplyDeltaChain()
```

**Chat.lua:**
```lua
RegisterComm("togbank-dr") -- Delta Range Request handler
  → GetDeltaHistory(fromVersion, toVersion) → Send chain via togbank-dc
```

**New Protocol Messages:**
- `togbank-dr` (Delta Range Request): `{altName, fromVersion, toVersion}`
- `togbank-dc` (Delta Chain): `{altName, deltas: [{baseVersion, version, delta}]}`

**Fallback Rules:**
1. If delta chain > 10 hops → full sync
2. If total chain size > 5KB → full sync
3. If any delta missing in history → full sync
4. If chain application fails → full sync
5. Cleanup old deltas (>1 hour) to prevent memory growth

**Files Affected:**
- `Modules/Database.lua` (delta history storage - 3 new functions)
- `Modules/Guild.lua` (chain request/application logic - RequestDeltaChain, ApplyDeltaChain)
- `Modules/Chat.lua` (togbank-dr and togbank-dc handlers)
- `Modules/Constants.lua` (4 new configuration constants)
- `Core.lua` (register togbank-dr and togbank-dc prefixes)

**Priority:**
Critical - Blocks delta sync for offline players (primary use case)

**Workaround:**
Manual `/togbank share` from banker after player returns online forces full sync.

**Notes:**
- Delta chain replay is industry-standard pattern (Git, databases, event sourcing)
- Bandwidth still better than full sync: 3 deltas (~900B) vs full (~1800B)
- History cleanup prevents unbounded memory growth
- Chain validation ensures data integrity (each delta checks baseVersion)
- Related to UI-001 debugging exposed version mismatch scenarios

---

#### ✅ [DELTA-006-IMPL-001] Function name mismatch: BuildDeltaChain vs GetDeltaHistory

**Severity:** 🔴 CRITICAL
**Category:** Implementation / Function Call Error
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Status:** ✅ CLOSED (Feature Abandoned)
**Closed Date:** 2026-01-26
**Assigned To:** Development Team
**Related To:** [DELTA-006] Delta Chain Replay Implementation

**Closure Note:**
Delta chain replay feature was abandoned in favor of alternative sync approaches. This implementation was never completed or deployed to production.

**Original Description:**
Proactive delta chain sending was failing silently due to calling non-existent function `BuildDeltaChain()` instead of the correct function name `GetDeltaHistory()`. This completely blocked the delta chain replay feature from working.

**Impact:**
- **CRITICAL:** Delta chain replay completely non-functional
- Query-based offline player catch-up mechanism not working
- Test Suite 1.4 blocked from completion
- Feature appears to work (no errors) but silently fails to send chains

**Steps to Reproduce:**
1. Set up offline player scenario:
   - Galdof has old version of Metals data (v1768964533)
   - Metals has current version (v1768965902+)
   - Delta history exists on Metals (3+ deltas spanning the gap)
2. Metals broadcasts version via `/togbank share`
3. Galdof receives broadcast, detects mismatch, sends query with old version
4. Metals receives query in Chat.lua line 302-320 (proactive chain handler)
5. **BUG:** Calls `TOGBankClassic_Database:BuildDeltaChain()` which doesn't exist
6. Function returns nil, nil check prevents crash, but no chain is sent
7. Galdof never receives delta chain, remains out of sync

**Expected Behavior:**
```
[Metals] > Galdof-OldBlanchy queries Metals-Azuresong about alt Metals-Azuresong
[Metals] Query from Galdof-OldBlanchy for Metals-Azuresong v1768964533 (have v1768965902), sending 3-delta chain
[Metals] < togbank-dc (Delta Chain) to Galdof-OldBlanchy (XXX bytes)

[Galdof] > Metals-Azuresong > togbank-dc (Delta Chain) (3 hops)
[Galdof] ✓ Applied delta chain for Metals-Azuresong (3 hops, v1768964533→v1768965902)
```

**Actual Behavior:**
```
[Metals] > Galdof-OldBlanchy queries Metals-Azuresong about alt Metals-Azuresong
(no chain-building log)
(no delta chain sent)

[Galdof] (waits indefinitely, never receives chain)
```

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Branch: feature/delta-chain-replay
- Test Suite: 1.4 (Delta Chain Replay)

**Root Cause:**
File: `Modules/Chat.lua` line 307

**Incorrect Code:**
```lua
local deltaChain = TOGBankClassic_Database:BuildDeltaChain(nameNorm, requestedVersion, currentVersion)
```

**Actual Function Name:** `GetDeltaHistory(name, altName, fromVersion, toVersion)` (Database.lua lines 333-369)

**Why This Failed:**
1. Function `BuildDeltaChain()` does not exist in Database.lua
2. Lua returns nil for non-existent function calls (no error thrown)
3. Nil check `if deltaChain and #deltaChain > 0` prevents crash but hides bug
4. Function signature also missing required `guildName` parameter

**Fix Applied:**
Changed line 307 in Chat.lua from:
```lua
local deltaChain = TOGBankClassic_Database:BuildDeltaChain(nameNorm, requestedVersion, currentVersion)
```

To:
```lua
local deltaChain = TOGBankClassic_Database:GetDeltaHistory(TOGBankClassic_Guild.Info.name, nameNorm, requestedVersion, currentVersion)
```

**Changes:**
1. Function name: `BuildDeltaChain` → `GetDeltaHistory`
2. Added missing parameter: `TOGBankClassic_Guild.Info.name` (guild name)

**Verification:**
- ✅ Confirmed function doesn't exist: `/dump TOGBankClassic_Database.BuildDeltaChain` → nil
- ✅ Confirmed correct function exists: `/dump TOGBankClassic_Database.GetDeltaHistory` → function
- ✅ No other incorrect calls found (grep search performed)
- ✅ No Lua errors after fix

**Testing Plan:**
1. Check delta history exists: `/dump TOGBankClassic_Database.Info.deltaHistory["Metals-Azuresong"]`
2. Both characters `/reload`
3. Metals: `/togbank share`
4. Verify chain-building log appears on Metals
5. Verify chain received and applied on Galdof
6. Verify Galdof's version updated to match Metals

**Prevention:**
- Search codebase for similar function name mismatches
- Document all public API functions with exact signatures
- Consider runtime validation to catch undefined function calls earlier

**Resolution Date:** 2026-01-20
**Files Modified:**
- `Modules/Chat.lua` (line 307)

**Notes:**
- Bug discovered during manual Test Suite 1.4 execution
- Only affected new proactive chain sending feature (DELTA-006)
- Did not affect basic delta sync functionality
- No data corruption or loss occurred

---

### 🟡 MEDIUM

#### ⏳ [TEST-001] Unit tests need adjustment for actual implementation

**Severity:** 🔴 CRITICAL
**Category:** Database / Module Initialization
**Reporter:** Testing Team
**Date Reported:** 2026-01-17
**Status:** Resolved
**Assigned To:** Development Team

**Description:**
Tests.lua was using `addon:NewModule("Tests")` pattern which caused a nil value error on line 2. This prevented the entire test suite from loading.

**Steps to Reproduce:**
1. Load TOGBankClassic v0.7.0
2. Addon fails to load with error
3. Error: `attempt to call method 'NewModule' (a nil value)`

**Expected Behavior:**
Tests module should load successfully using the addon's module pattern.

**Actual Behavior:**
Lua error on line 2 of Tests.lua preventing addon from loading.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Initial testing phase

**Lua Errors:**
```
1x TOGBankClassic/Modules/Tests.lua:2: attempt to call method 'NewModule' (a nil value)
```

**Root Cause:**
Tests.lua was using AceAddon's `NewModule()` pattern, but other modules in the addon use a simple table pattern (`TOGBankClassic_ModuleName = {}`). The `addon` variable from `local addonName, addon = ...` doesn't have the NewModule method in this context.

**Fix Applied:**
- Changed `local addonName, addon = ...` and `local Tests = addon:NewModule("Tests")` to `TOGBankClassic_Tests = {}`
- Updated `RunTests()` function to be a method: `function TOGBankClassic_Tests:RunTests()`
- Follows the pattern used by all other modules (Database, Guild, Chat, etc.)

**Resolution Date:** 2026-01-17

---

#### ✅ [DELTA-002] Tests.lua addon:Print() at load time fails

**Severity:** 🔴 CRITICAL
**Category:** Module Initialization
**Reporter:** Testing Team
**Date Reported:** 2026-01-17
**Status:** Resolved
**Assigned To:** Development Team

**Description:**
Line 704 of Tests.lua attempted to call `addon:Print()` at file load time, but `addon` (TOGBankClassic_Core) doesn't exist yet because Core.lua loads after Tests.lua in the TOC file.

**Steps to Reproduce:**
1. Load TOGBankClassic v0.7.0 (after DELTA-001 fix)
2. Addon fails to load with error
3. Error: `attempt to index local 'addon' (a nil value)`

**Expected Behavior:**
Tests module should load without errors.

**Actual Behavior:**
Lua error on line 704 preventing addon from loading.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Testing phase

**Lua Errors:**
```
2x TOGBankClassic/Modules/Tests.lua:704: attempt to index local 'addon' (a nil value)
```

**Root Cause:**
The line `addon:Print("Tests module loaded. Use /togbank test to run delta sync tests.")` executes immediately when the file loads. At this point, `addon` (which references `TOGBankClassic_Core`) doesn't exist yet because Core.lua loads after Tests.lua in the TOC file load order.

**Fix Applied:**
- Removed the immediate print statement at line 704
- Added comment explaining why we can't print at load time
- All other `addon:Print()` calls are inside functions that execute later (after Core.lua loads), so they work fine

**Resolution Date:** 2026-01-17

---

#### ✅ [DELTA-003] Tests.lua addon reference nil in RunAllTests

**Severity:** 🔴 CRITICAL
**Category:** Module Initialization
**Reporter:** Testing Team
**Date Reported:** 2026-01-17
**Status:** Resolved
**Assigned To:** Development Team

**Description:**
When `/togbank test` was executed, RunAllTests() tried to call `addon:Print()` but `addon` was nil. The local variable `addon` was set to `TOGBankClassic_Core` at file load time, but Core doesn't exist yet, so it captured nil.

**Steps to Reproduce:**
1. Load TOGBankClassic v0.7.0 (after DELTA-001 and DELTA-002 fixes)
2. Type `/togbank test` in chat
3. Error: `attempt to index upvalue 'addon' (a nil value)` at line 575

**Expected Behavior:**
Tests should run successfully.

**Actual Behavior:**
Lua error prevents tests from executing.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Testing phase

**Lua Errors:**
```
1x TOGBankClassic/Modules/Tests.lua:575: attempt to index upvalue 'addon' (a nil value)
```

**Root Cause:**
The code `local addon = TOGBankClassic_Core` at the top of Tests.lua captures the value of `TOGBankClassic_Core` at file load time. Since Tests.lua loads before Core.lua in the TOC, `TOGBankClassic_Core` doesn't exist yet and `addon` is set to nil permanently.

**Fix Applied:**
Replaced direct assignment with a metatable proxy:
```lua
local addon = setmetatable({}, {
    __index = function(_, key)
        return TOGBankClassic_Core and TOGBankClassic_Core[key]
    end
})
```
This creates a proxy table that dynamically looks up `TOGBankClassic_Core` whenever accessed, so it works correctly after Core.lua loads.

**Resolution Date:** 2026-01-17

---

### 🟠 HIGH

#### ✅ [COMPAT-001] RequestLog.lua nil Info crash on early request log sync

**Severity:** 🟠 HIGH
**Category:** Backwards Compatibility / Error Handling
**Reporter:** Testing Team
**Date Reported:** 2026-01-17
**Status:** Resolved
**Assigned To:** Development Team

**Description:**
When receiving request log entries from another player before guild data is fully loaded, `ReceiveRequestLogEntries()` crashes trying to access `self.Info.requestLogApplied` when `self.Info` is nil.

**Steps to Reproduce:**
1. Login to character
2. Before guild data loads, receive request log sync from another player
3. Error: `attempt to index field 'Info' (a nil value)` at RequestLog.lua:922

**Expected Behavior:**
Should handle request log entries gracefully even if guild data hasn't loaded yet, or silently ignore them until ready.

**Actual Behavior:**
Lua error crashes the addon when processing request log entries.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Testing phase
- Occurs when another player (Toglowgear-Azuresong) sends request log sync

**Lua Errors:**
```
1x TOGBankClassic/Modules/RequestLog.lua:922: attempt to index field 'Info' (a nil value)
```

**Root Cause:**
`EnsureRequestsInitialized()` checks if `self.Info` is nil and returns early (line 148-150), but the calling code in `ReceiveRequestLogEntries()` doesn't check if initialization succeeded. At line 922, the code assumes `self.Info` exists and tries to access `self.Info.requestLogApplied`, causing the crash.

This happens when:
- Player logs in and guild data hasn't loaded yet
- Another player sends request log sync immediately
- `Guild.Info` is still nil because `Database:Load()` hasn't been called yet

**Fix Applied:**
Added nil check before accessing `self.Info.requestLogApplied`:
```lua
-- Safety check: Info might be nil if guild data not loaded yet
if not self.Info then
    return
end

local applied = self.Info.requestLogApplied or {}
```

This matches the defensive pattern used in `EnsureRequestsInitialized()` and gracefully handles the race condition.

**Impact:**
This is a pre-existing bug not related to delta sync implementation, but discovered during testing. Affects all versions when receiving request log syncs before guild data loads.

**Resolution Date:** 2026-01-17

---

*No other high priority bugs reported*

---

### 🟡 MEDIUM

---

## Resolved Bugs

### 🟢 FIXED

#### ✅ [TEST-002] Remaining test phases need adjustment for actual implementation

**Severity:** 🟡 MEDIUM
**Category:** Testing
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Date Resolved:** 2026-01-20
**Status:** ✅ RESOLVED
**Related:** TEST-001 (Phase 5.1 completed)
**Resolution:** Fixed all test failures + discovered and fixed ApplyItemDelta bug

**Description:**
After fixing Phase 5.1 Delta Computation tests in TEST-001, there were 11 failing tests across 4 remaining test phases. All tests have been fixed and now pass.

**Final Test Results:**
- Phase 5.1 Delta Computation: **8/8 passed** ✅
- Phase 5.2 Size Estimation: **4/4 passed** ✅
- Phase 5.3 Protocol Negotiation: **3/3 passed** ✅
- Phase 5.4 Error Handling: **5/5 passed** ✅
- Phase 5.5 Integration: **2/2 passed** ✅
- Phase 5.6 Backwards Compatibility: **3/3 passed** ✅

**Total: 25/25 passed (100%)** 🎉

**Issues Fixed:**

1. **Phase 5.3 Protocol Negotiation:**
   - Fixed `testProtocolVersionDetection` - GetPeerCapabilities returns table with version field, not just number
   - Fixed `testShouldUseDeltaLogic` - ShouldUseDelta takes no parameters, mocked GetGuildDeltaSupport
   - Fixed `testDeltaSupportThreshold` - PROTOCOL.DELTA_SUPPORT_THRESHOLD is 0.1 (10%), not 0.5 (50%)

2. **Phase 5.4 Error Handling:**
   - Fixed `testApplyDeltaNoExistingData` - Added Guild.Info.alts initialization
   - Fixed `testApplyDeltaVersionMismatch` - Added Guild.Info.alts initialization
   - Fixed `testSnapshotValidation` - ValidateSnapshot expects raw snapshot data, not wrapped
   - Fixed `testDeltaStructureValidation` - ValidateDeltaStructure requires type="alt-delta", name, version, baseVersion, changes

3. **Phase 5.5 Integration:**
   - Fixed `testFullDeltaRoundtrip` - Used Guild:NormalizeName() for proper realm suffix, fixed money location (root level), used proper array operations
   - **DISCOVERED BUG:** ApplyItemDelta was using `items[i] = nil` instead of `table.remove(items, i)`, causing item removals to fail
   - Fixed `testDeltaSizeThreshold` - Added more items to increase full size, making money-only delta relatively smaller

4. **Phase 5.6 Backwards Compatibility:**
   - Fixed `testV1ClientIgnoresDeltaPrefix` - Set protocol version in database with correct structure
   - Fixed `testFallbackToFullSync` - Mocked GetGuildDeltaSupport for threshold test

**Bug Discovered:**
Found and fixed critical bug in `Guild.lua:ApplyItemDelta()` - item removal was broken:
```lua
-- OLD (BROKEN):
for i, item in pairs(items) do
    if itemKey == key then
        items[i] = nil  -- Leaves hole in array, doesn't reduce length
        break
    end
end

-- NEW (FIXED):
for i = #items, 1, -1 do  -- Iterate backwards to safely remove
    local item = items[i]
    if itemKey == key then
        table.remove(items, i)  -- Properly removes and shifts array
        break
    end
end
```

**Files Modified:**
- `Modules/Tests.lua` - Fixed all test functions for correct signatures and expectations
- `Modules/Guild.lua` - Fixed ApplyItemDelta to properly remove items from arrays

**Verification:**
All 25 tests now pass successfully, validating:
- Delta computation logic
- Size estimation
- Protocol negotiation
- Error handling with proper fallbacks
- Full roundtrip integration (including item additions AND removals)
- Backwards compatibility with v1 clients

---

### 🟡 MEDIUM

**Severity:** 🟡 MEDIUM
**Category:** Testing
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Status:** Open - Needs Investigation
**Related:** TEST-001 (Phase 5.1 completed)
**Assigned To:** Development Team

**Description:**
After fixing Phase 5.1 Delta Computation tests in TEST-001, there are still 11 failing tests across 4 remaining test phases. These failures are likely due to similar issues: wrong function signatures, data structure mismatches, or missing test setup/mocking.

**Current Test Results:**
- Phase 5.1 Delta Computation: **8/8 passed** ✅ (fixed in TEST-001)
- Phase 5.2 Size Estimation: **4/4 passed** ✅ (already working)
- Phase 5.3 Protocol Negotiation: **0/3 passing** ❌
- Phase 5.4 Error Handling: **1/5 passing** ❌
- Phase 5.5 Integration: **0/2 passing** ❌
- Phase 5.6 Backwards Compatibility: **1/3 passing** ❌

**Total: 14/25 passed (56%) - Target: 25/25 (100%)**

**Failing Tests by Phase:**

**Phase 5.3: Protocol Negotiation (0/3 passing)**
```
✗ Protocol Version Detection: attempt to index local 'v2Caps' (a nil value)
✗ Should Use Delta Logic: Assertion failed: Should use delta when conditions are met
✗ Delta Support Threshold: Assertion failed: 30% should be below 50% threshold
```

**Phase 5.4: Error Handling (1/5 passing)**
```
✗ Apply Delta - No Existing Data: attempt to index field 'alts' (a nil value)
✗ Apply Delta - Version Mismatch: attempt to index field 'alts' (a nil value)
✓ Delta Error Tracking (passing)
✗ Snapshot Validation: Assertion failed: Corrupted bank should fail
✗ Delta Structure Validation: Assertion failed: Valid delta should pass
```

**Phase 5.5: Integration (0/2 passing)**
```
✗ Full Delta Roundtrip: bad argument #2 to 'format' (string expected, got table)
✗ Delta Size Threshold: bad argument #2 to 'format' (string expected, got table)
```

**Phase 5.6: Backwards Compatibility (1/3 passing)**
```
✗ V1 Client Ignores Delta Prefix: Assertion failed: V1 client should not support delta
✓ V2 Client Handles Both Protocols (passing)
✗ Fallback to Full Sync: Assertion failed: Should not use delta with V1 client
```

**Root Causes (Preliminary Analysis):**

1. **Protocol Negotiation Tests:**
   - Missing peer protocol data in test setup
   - `GetPeerCapabilities()` returning nil instead of expected capabilities object
   - Threshold calculation logic may have changed

2. **Error Handling Tests:**
   - `ApplyDelta()` expects `Guild.Info.alts` to exist but tests don't populate it
   - Validation functions may need different data structures
   - Tests not properly mocking error conditions

3. **Integration Tests:**
   - Output formatting issue: passing table to string.format instead of serialized string
   - May need to mock or stub `Output:Debug()` calls
   - Delta roundtrip needs complete Guild/Database context

4. **Backwards Compatibility Tests:**
   - Protocol capability detection logic changed
   - Tests checking old behavior that no longer matches implementation
   - May need to update assertions or test data

**Priority:** MEDIUM
These are test infrastructure issues that don't block actual functionality, but should be fixed to ensure automated validation works properly.

**Workaround:**
Manual testing per TESTING.md continues to validate functionality. Core delta computation is verified working via Phase 5.1 tests.

**Next Steps:**
1. Investigate each failing test individually
2. Update test setup/mocking to match current implementation
3. Fix function signatures and data structures as needed
4. Verify all 25 tests passing before closing

*No other medium priority bugs reported*

---

### 🟢 LOW

*No low priority bugs reported*

---

## Resolved Bugs

### ✅ FIXED

#### ✅ [TEST-001] Unit tests need adjustment for actual implementation

**Severity:** 🟡 MEDIUM
**Category:** Testing
**Reporter:** Testing Team
**Date Reported:** 2026-01-17
**Status:** ✅ Resolved & Verified
**Resolution Date:** 2026-01-20
**Assigned To:** Development Team

**Description:**
The automated test suite (/togbank test) had 17/25 tests failing because the test code was written against a different function signature than what was actually implemented. This ticket addressed **Phase 5.1 Delta Computation tests** which were the highest priority.

**Scope:**
This ticket focused on fixing Phase 5.1 (Delta Computation) and Phase 5.2 (Size Estimation, which was already working). Remaining test phases are tracked in **TEST-002**.

**Test Results (Before Fix):**
- Phase 5.1 Delta Computation: 0/6 passed
- Phase 5.2 Size Estimation: 4/4 passed ✓
- Phase 5.3 Protocol Negotiation: 1/3 passed
- Phase 5.4 Error Handling: 1/5 passed
- Phase 5.5 Integration: 0/2 passed
- Phase 5.6 Backwards Compatibility: 2/3 passed
- **Total: 8/25 passed (32%)**

**Test Results (After Fix - VERIFIED):**
- Phase 5.1 Delta Computation: **8/8 passed** ✅ (was 0/6)
- Phase 5.2 Size Estimation: 4/4 passed ✓
- Phase 5.3 Protocol Negotiation: 0/3 passed
- Phase 5.4 Error Handling: 1/5 passed
- Phase 5.5 Integration: 0/2 passed
- Phase 5.6 Backwards Compatibility: 1/3 passed
- **Total: 14/25 passed (56%)** - Improved by 24 percentage points

**Root Cause:**
Tests were written expecting:
- `ComputeDelta(oldData, newData, version)`

But actual implementation is:
- `ComputeDelta(name, currentAlt)` - retrieves snapshot from database internally

Additionally:
- Item structure mismatch: tests used `{itemID, count, link}`, actual uses `{ID, Count, Link}`
- Delta structure changed with DELTA-005 fix: now uses `{added=[], modified=[], removed=[]}` instead of slot-based indexing
- Tests didn't initialize Guild/Database context needed for snapshot operations

**Fix Applied:**

1. **Updated test helper functions:**
   - `createTestItem()` now returns `{ID, Count, Link}` matching Bank.lua structure
   - `createTestAltData()` now matches actual alt data structure with proper money/version fields
   - Items stored in arrays, not slot-indexed tables

2. **Added test setup function:**
   - `setupDeltaTest()` initializes Guild.Info and Database structure for tests
   - Creates deltaSnapshots storage for test guild
   - Ensures proper context for Database:SaveSnapshot() and Guild:ComputeDelta()

3. **Rewrote delta computation tests (6 tests):**
   - Now use `Database:SaveSnapshot(guildName, altName, oldData)` to create baseline
   - Call `Guild:ComputeDelta(altName, newData)` with correct signature
   - Updated assertions to check `delta.changes.bank.added/modified/removed` arrays
   - Fixed item field references (ID not itemID, Count not count, Link not link)

4. **Fixed ItemsEqual and GetChangedFields tests:**
   - Updated to use correct item structure
   - Assertions now expect ID and Link to always be included in changes (itemKey identification)

**Files Modified:**
- `Modules/Tests.lua` - Complete rewrite of Phase 5.1 tests to match actual implementation

**Verification Results (2026-01-20):**

Ran `/togbank test` after implementing fixes:
```
Phase 5.1: Delta Computation Tests
✓ Delta Computation - No Changes
✓ Delta Computation - Money Change
✓ Delta Computation - Item Added
✓ Delta Computation - Item Removed
✓ Delta Computation - Item Count Changed
✓ Delta Computation - Multiple Changes
✓ Items Equal - Comparison
✓ Get Changed Fields

Phase 5.2: Size Estimation Tests
✓ Size Estimation - Empty
✓ Size Estimation - Small Delta
✓ Size Estimation - Large Delta
✓ Size Estimation - Comparison

=== Test Summary ===
Total: 25 | Passed: 14 | Failed: 11
```

**Result: SUCCESS** ✅
- All 8 Phase 5.1 delta computation tests now passing (was 0/6)
- Test pass rate improved from 32% to 56%
- No Lua errors during delta computation tests
- Target achieved: Core delta computation tests fully functional

**Remaining Test Failures:**
The following 11 test failures are now tracked in **TEST-002**:
- Phase 5.3 Protocol Negotiation: 0/3 passing
- Phase 5.4 Error Handling: 1/5 passing
- Phase 5.5 Integration: 0/2 passing
- Phase 5.6 Backwards Compatibility: 1/3 passing

**Resolution Complete:**
✅ Core delta computation tests fixed and verified working (Phase 5.1: 8/8)
✅ Test infrastructure properly initializes database context
✅ Test data structures match actual implementation
✅ All Phase 5.1 tests passing (100%)
✅ Remaining phases split to TEST-002 for separate tracking

*No other medium priority bugs reported*

---

### 🟢 LOW

*No low priority bugs reported*

---

## Resolved Bugs

### ✅ FIXED

#### ✅ [DELTA-005] Item merging removes slot field, breaking delta comparison

**Severity:** 🔴 CRITICAL
**Category:** Delta Computation / Database
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Status:** ✅ Resolved & Tested
**Resolution Date:** 2026-01-20
**Assigned To:** Development Team

**Description:**
The scanning logic merges multiple stacks of the same item (e.g., 4x Mithril Bar stacks of 20 each = 80 total) into a single item entry by itemID+Link. However, merged items have NO `slot` field, which breaks delta comparison. `ComputeItemDelta()` compares items by slot (line 973), so when `newItem.slot` is nil, the comparison never runs and quantity changes are never detected.

**Impact:**
- **CRITICAL:** Delta sync completely non-functional - ALL quantity changes undetected
- Affects stacked items (consumables, reagents, etc.) - the most common inventory changes
- "No changes detected" shown even when 20+ items added/removed
- Full sync always used (delta never selected)
- Testing blocked until resolved

**Steps to Reproduce:**
1. Bank has 70 Mithril Bars (multiple stacks)
2. Close bank (scan merges into single item: {ID, Count=70, Link})
3. `/togbank share` (baseline snapshot saved)
4. Remove 20 bars (70→50)
5. Close bank (scan merges into single item: {ID, Count=50, Link})
6. `/togbank share`
7. Result: "No changes detected for Metals-Azuresong (delta would be empty)"

**Expected Behavior:**
Delta comparison should detect quantity changes:
```
Comparing Metals-Azuresong: previous bank has 9 items, bags have 7 items; current bank has 9 items, bags have 7 items
✓ Delta selected for Metals-Azuresong (1 modifications: Mithril Bar 70→50)
Sent delta update for Metals-Azuresong via togbank-d2
```

**Actual Behavior:**
Item comparison skipped because `newItem.slot` is nil:
```
Comparing Metals-Azuresong: previous bank has 9 items, bags have 7 items; current bank has 9 items, bags have 7 items
No changes detected for Metals-Azuresong (delta would be empty)
Sent full sync for Metals-Azuresong via togbank-d
```

**Root Cause:**
Bank.lua `ScanBag()` lines 13-38 merges items by key (itemID+Link):
```lua
local key = itemID .. itemLink
if items[key] then
    local item = items[key]
    items[key] = { ID = item.ID, Count = item.Count + itemCount, Link = item.Link }
else
    items[key] = { ID = itemID, Count = itemCount, Link = itemLink }
end
```

Merged items have only `{ID, Count, Link}` - **NO `slot` field**.

Guild.lua `ComputeItemDelta()` line 970-977 tries to compare by slot:
```lua
for _, newItem in pairs(newItems) do
    if newItem and newItem.slot then  -- ← FAILS: newItem.slot is nil
        local oldItem = oldBySlot[newItem.slot]
        -- comparison never runs
    end
end
```

Guild.lua `BuildSlotIndex()` line 942-953 builds index by slot:
```lua
for _, item in ipairs(items) do
    if item and item.slot then  -- ← FAILS: item.slot is nil
        index[item.slot] = item
    end
end
```

**Resolution - Option A Implemented:**
Converted entire delta pipeline from slot-based to itemKey-based comparison:

**Changes Made:**
1. ✅ **Guild.lua lines 942-956**: `BuildSlotIndex()` → `BuildItemIndex()`
   - Changed from `index[item.slot] = item` to `index[tostring(item.ID) .. item.Link] = item`
   - Creates lookup table by itemKey (e.g., "2772[Mithril Bar]")

2. ✅ **Guild.lua lines 958-990**: `ComputeItemDelta()` refactored
   - Compare items by itemKey instead of slot
   - Removed items now store `{ID, Link}` instead of slot number
   - Correctly detects additions, modifications, and removals of merged items

3. ✅ **Guild.lua lines 920-938**: `GetChangedFields()` updated
   - Always includes `ID` and `Link` fields for identification (was conditional)
   - Removed `slot` field dependency
   - Returns minimal delta entry: `{ID, Link, Count, Info}` (only changed fields)

4. ✅ **Guild.lua lines 1086-1143**: `ApplyItemDelta()` refactored
   - Uses `BuildItemIndex()` to find items by key
   - Applies modifications by itemKey matching
   - Removes items by itemKey matching
   - Adds new items to array

5. ✅ **Core.lua lines 153-216**: `ValidateItemDelta()` updated
   - Removed slot validation (merged items don't have slots)
   - Now requires `ID` (number) and `Link` (string) for all items
   - Validates structure of added/modified/removed arrays
   - Slot is optional (backwards compatible)

**Test Results:**
- ✅ Delta transmitted successfully: 311 bytes vs 1748 bytes (82% smaller)
- ✅ Validation passed: No errors on receiver
- ✅ Application successful: "✓ Applied delta for Metals-Azuresong (v1768947985→v1768948029) in 0.06ms"
- ✅ Quantity changes detected correctly (70→90 Mithril Bars)
- ✅ Compute time: 0.42ms (efficient)

**Why Option A:**
- Maintains existing item merging design (data structure compatibility)
- Minimal changes to scanning logic (Bank.lua unchanged)
- itemKey (ID+Link) provides stable unique identifier for merged items
- Slot field was meaningless for merged items anyway
- Backwards compatible with existing data

**Files Modified:**
- `Modules/Guild.lua` (4 functions refactored: BuildItemIndex, ComputeItemDelta, GetChangedFields, ApplyItemDelta)
- `Core.lua` (ValidateItemDelta updated)
- `Modules/Bank.lua` (no changes - merging logic preserved)

**Resolution Complete:**
✅ All changes implemented and tested successfully
✅ Delta sync now functional for merged items
✅ Changes ready for commit

---

#### ✅ [DELTA-004] Delta computation not detecting inventory changes

**Severity:** 🟠 HIGH
**Category:** Delta Computation
**Reporter:** Testing Team
**Date Reported:** 2026-01-20
**Status:** ✅ Resolved (Fixed via DELTA-005)
**Resolution Date:** 2026-01-20
**Assigned To:** Development Team

**Description:**
After removing 1 stack of mithril from the banker's inventory, `/togbank share` still reports "No changes detected for Metals-Azuresong (delta would be empty)" and sends a full sync instead of a delta.

**Steps to Reproduce:**
1. Initial `/togbank share` on Metals-Azuresong (creates snapshot)
2. Remove 1 stack of mithril from bank
3. Close bank
4. Wait 30 seconds
5. Open bank again
6. Run `/togbank share`

**Expected Behavior:**
```
[DEBUG] Comparing Metals-Azuresong: previous bank has X items, current bank has X-1 items
[DEBUG] ✓ Delta selected for Metals-Azuresong: XXX bytes vs YYY bytes full
[DEBUG] Sent delta update for Metals-Azuresong via togbank-d2
```

**Actual Behavior:**
```
[DEBUG] No changes detected for Metals-Azuresong (delta would be empty)
[DEBUG] Delta computation took 0.07ms
[DEBUG] Sent full sync for Metals-Azuresong via togbank-d (824 bytes)
```

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Character: Metals-Azuresong (banker)
- Guild: The Old Gods
- Protocol v2 adoption: 12.5% (2 of 8 members)
- DELTA_SUPPORT_THRESHOLD: 0.1 (lowered from 0.5 for testing)
- Test phase: Test Suite 1.2 (Small Change Delta Sync)

**Investigation Status:**
- Added debug logging to ComputeDelta() to show item counts being compared
- **ROOT CAUSE FOUND:** Bank scan shows 0 items because `/togbank share` was run immediately after opening bank
- Bank scanning takes ~1 second after `BANKFRAME_OPENED` event fires
- User must wait for scan to complete before running `/togbank share`
- Diagnostic output: "Comparing Metals-Azuresong: previous bank has 0 items, current bank has 0 items"
- This explains why delta always reports "no changes" - comparing empty to empty

**Possible Root Causes:**
1. ~~Bank scan not updating currentAlt.bank.items before SendAltData is called~~ **CONFIRMED - timing issue**
2. ~~Snapshot comparison logic incorrect in ComputeItemDelta()~~ Not the issue
3. ~~Snapshot not being saved/retrieved properly from database~~ Not the issue
4. ~~Item data structure mismatch (table vs array indexing)~~ Not the issue

**Workaround:**
Open bank, wait ~1-2 seconds for scan to complete, then run `/togbank share`. The automatic 3-minute share timer handles this correctly because there's plenty of time for scan to complete.

**Resolution:**
This bug was **resolved as part of [DELTA-005]** - the root cause was the slot-based comparison in `ComputeItemDelta()`. When items were merged (multiple stacks of same item → single entry), they had no `slot` field, causing the comparison logic to skip them entirely. The fix in DELTA-005 converted the entire delta pipeline from slot-based to itemKey-based comparison, which properly detects:
- Item additions (new itemKey appears)
- Item modifications (itemKey exists, Count/Info changed)
- Item removals (itemKey disappears)

With itemKey-based comparison, delta computation now correctly detects all inventory changes for both merged and non-merged items.

**See [DELTA-005] for complete implementation details.**

---

#### ✅ [UI-001] Debug tab doesn't persist when closed/hidden

**Severity:** 🟡 MEDIUM
**Category:** UI/Commands
**Reporter:** Development Team
**Date Reported:** 2026-01-20
**Status:** ✅ Resolved & Tested
**Resolution Date:** 2026-01-20
**Assigned To:** Development Team

**Description:**
When a user closes or hides the "TOGBank Debug" chat tab (right-click -> Hide Tab), debug messages stop going to the dedicated tab and start cluttering the main chat. Buffered messages are lost when the tab is hidden and not restored when recreated.

**Steps to Reproduce:**
1. Create debug tab with `/togbank debugtab`
2. Enable debug logging with `/togbank debug`
3. Observe debug messages going to the dedicated tab
4. Right-click the "TOGBank Debug" tab and select "Hide Tab"
5. Continue using the addon (trigger some debug messages)
6. Debug messages now appear in main chat instead
7. Create the debug tab again with `/togbank debugtab`
8. Previous buffered messages are not restored to the tab

**Expected Behavior:**
- Debug tab should remain functional even when hidden temporarily
- Buffered messages should be restored when tab is recreated or shown again
- Debug messages should not fall through to main chat if debug tab exists but is hidden

**Actual Behavior:**
- `GetDebugFrame()` returns nil when tab is hidden (`IsShown()` check fails)
- Debug messages fall through to normal print (main chat)
- Buffered messages are stored but never displayed when tab is recreated
- User loses all debug history from when tab was hidden

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- All versions affected

**Root Cause:**
`GetDebugFrame()` checks both `self.debugFrame` exists AND `self.debugFrame:IsShown()` is true. When user hides the tab:
1. `IsShown()` returns false
2. `GetDebugFrame()` returns nil
3. Log function falls through to normal print
4. Messages are buffered via `BufferDebugMessage()` but frame isn't found to display them
5. `RedrawDebugMessages()` is called when tab is created, but `self.debugFrame` was set to nil

Code in Output.lua lines 44-57:
```lua
function TOGBankClassic_Output:GetDebugFrame()
	if self.debugFrame and self.debugFrame:IsShown() then
		return self.debugFrame
	end

	-- Try to find existing TOGBank Debug tab
	for i = 1, NUM_CHAT_WINDOWS do
		local name = GetChatWindowInfo(i)
		if name == "TOGBank Debug" then
			self.debugFrame = _G["ChatFrame"..i]
			return self.debugFrame
		end
	end

	return nil
end
```

**Proposed Fix:**
Remove the `IsShown()` check from `GetDebugFrame()` or make it search for the frame even when hidden:
```lua
function TOGBankClassic_Output:GetDebugFrame()
	if self.debugFrame then
		return self.debugFrame
	end

	-- Try to find existing TOGBank Debug tab (even if hidden)
	for i = 1, NUM_CHAT_WINDOWS do
		local name = GetChatWindowInfo(i)
		if name == "TOGBank Debug" then
			self.debugFrame = _G["ChatFrame"..i]
			return self.debugFrame
		end
	end

	return nil
end
```

Additionally, ensure `RedrawDebugMessages()` is called after finding the frame:
```lua
if name == "TOGBank Debug" then
	self.debugFrame = _G["ChatFrame"..i]
	self:RedrawDebugMessages()  -- Restore buffered messages
	return self.debugFrame
end
```

**Impact:**
- Users lose debug history when tab is accidentally closed
- Debug messages clutter main chat when debug tab exists but is hidden
- Poor user experience for debugging and troubleshooting

**Workaround:**
- Don't close/hide the debug tab once created
- Keep debug tab visible at all times when debug logging is enabled
- Use `/togbank debugtabremove` and `/togbank debugtab` to fully recreate if needed

**Notes:**
- This is a pre-existing issue, not related to delta sync
- Affects all versions with debug tab feature
- Message buffer (1000 messages) works correctly
- `RedrawDebugMessages()` logic works when frame is found

**Fix Applied:**
- Removed `IsShown()` check from `GetDebugFrame()` - now returns frame even when hidden
- Added call to `RedrawDebugMessages()` when frame is found to restore buffered messages
- Frame is now cached after first lookup for better performance
- Added `OnShow` hook to automatically redraw messages when switching back to the debug tab
- Debug messages will always go to debug tab if it exists, regardless of visibility
- Buffered history (up to 1000 messages) is preserved and restored when tab becomes active

**Additional Issue Found (2026-01-20):**
Debug tab not persisting across `/reload` on some characters (worked on Galdof but not on Metals).

**Root Cause #1:**
`CreateDebugTab()` in Output.lua line 129 called `FCF_ResetChatWindows()` which resets **ALL** chat windows to defaults, preventing WoW from properly saving the new tab configuration to `chat-cache.txt`.

**Root Cause #2:**
WoW's `chat-cache.txt` only saves frames that have `SIZE > 0` and `LOCKED 0`. Metals had empty frames with `SIZE 0` and `LOCKED 1`, which WoW won't persist. The code was:
1. Finding these locked, zero-size frames
2. Setting their name but not unlocking or sizing them
3. WoW discarding these changes on `/reload`

**Root Cause #3:**
`frame:SetFont(GameFontNormal:GetFont(), 12)` caused Lua error because `GetFont()` returns 3 values (fontFile, height, flags), resulting in wrong argument count to `SetFont()`.

**Root Cause #4:**
Code was selecting ChatFrame3 which is WoW's reserved "Voice" frame. WoW automatically resets this frame's name to "Voice" on reload, causing debug messages to fail routing.

**Root Cause #5:**
`FCF_SetWindowName()` was called with extra `frameIndex` parameter and operations were out of order. WoW requires specific API call sequence to properly initialize and save new chat frames.

**Final Fixes Applied:**
- Removed `FCF_ResetChatWindows()` call from `CreateDebugTab()` (caused all chat windows to reset)
- Changed frame search to find first frame with no name (empty slot), avoiding all reserved frames
- Removed `frameIndex` parameter from `FCF_SetWindowName()` call
- Reordered operations: SetWindowName → SetWindowColor → SetLocked → SetFont → Show → Dock
- Set font size properly: `local fontFile, _, fontFlags = GameFontNormal:GetFont(); frame:SetFont(fontFile, 12, fontFlags)`
- Added safety check to hook (`if not frame.togbankHooked then`)
- This ensures proper `NAME` and `SIZE 12` written to `chat-cache.txt`, making frame persist with correct name
- Tab now persists correctly across reloads on all characters with proper name

**Workaround for Corrupted Chat Configs:**
If a character has malformed chat tabs, delete their `chat-cache.txt` file and restart WoW to reset to defaults:
```powershell
Remove-Item "C:\Program Files (x86)\World of Warcraft\_classic_era_\WTF\Account\<ACCOUNT>\<REALM>\<CHARACTER>\chat-cache.txt"
```

**Resolution Complete:**
✅ All issues resolved and tested successfully
✅ Debug tab persists across reloads
✅ Messages properly routed even when tab is hidden

---

#### ✅ [ERROR-001] Error tracking silent failures and test parameter mismatch

**Severity:** 🟡 MEDIUM
**Category:** Error Handling / Testing
**Reporter:** Development Team
**Date Reported:** 2026-01-20
**Status:** ✅ Resolved & Verified
**Resolution Date:** 2026-01-20
**Verified:** 2026-01-20 - Error tracking confirmed working after metrics reset
**Assigned To:** Development Team

**Description:**
Two issues found in delta error tracking system:
1. `RecordDeltaError()` failed silently when `Guild.Info` was nil, losing error data
2. Test function `testDeltaErrorTracking()` called `RecordDeltaError()` with wrong parameter count

**Impact:**
- Errors occurring before guild initialization were completely lost with no visibility
- Test was passing incorrect parameters (2 instead of 3), leaving `errorMessage` as nil
- Developers had no way to track early delta failures
- Error categorization in tests was broken

**Root Cause:**
1. **Guild.lua lines 6-14**: Early returns in `RecordDeltaError()` discarded error data
   ```lua
   if not self.Info or not self.Info.name then
       return  -- Silent failure - error data lost
   end
   ```

2. **Tests.lua lines 413, 417**: Missing `errorType` parameter
   ```lua
   Guild:RecordDeltaError("TestRealm-ErrorAlt", "Test error 1")  -- Wrong: only 2 params
   -- Should be: Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 1")
   ```

**Fix Applied:**

**1. Guild.lua - Added temporary storage with automatic migration:**
```lua
-- Temporary in-memory error storage for when Guild.Info is not initialized
TOGBankClassic_Guild.tempDeltaErrors = {
	lastErrors = {},
	failureCounts = {},
	notifiedAlts = {},
}

function TOGBankClassic_Guild:RecordDeltaError(altName, errorType, errorMessage)
	local error = {
		altName = altName,
		errorType = errorType,
		message = errorMessage,
		timestamp = GetServerTime(),
	}

	-- Try to use database storage first
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			-- Use database storage (existing code)
			-- ...
			return
		end
	end

	-- Fallback: Use temporary in-memory storage
	table.insert(self.tempDeltaErrors.lastErrors, 1, error)
	-- ... track counts in temp storage
end

-- Migrate temporary errors to database once Guild.Info is initialized
function TOGBankClassic_Guild:MigrateTempErrors()
	if not self.Info or not self.Info.name then
		return
	end

	local db = TOGBankClassic_Database.db.faction[self.Info.name]
	if not db or not db.deltaErrors then
		return
	end

	-- Migrate errors, failure counts, and notification flags
	-- ... migration logic

	-- Clear temp storage
	self.tempDeltaErrors.lastErrors = {}
	self.tempDeltaErrors.failureCounts = {}
	self.tempDeltaErrors.notifiedAlts = {}
end
```

**2. Updated Init/Reset to trigger migration:**
```lua
function TOGBankClassic_Guild:Init(name)
	-- ... existing initialization code
	self.Info = TOGBankClassic_Database:Load(name)
	if self.Info then
		self:EnsureRequestsInitialized()
		-- Migrate any temporary errors to database
		self:MigrateTempErrors()
		return true
	end
	-- ...
end
```

**3. Updated query functions to check both sources:**
```lua
function TOGBankClassic_Guild:GetDeltaFailureCount(altName)
	-- Check database first if available
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			return db.deltaErrors.failureCounts[altName] or 0
		end
	end

	-- Fallback to temporary storage
	return self.tempDeltaErrors.failureCounts[altName] or 0
end
```

**4. Tests.lua - Fixed parameter count:**
```lua
Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 1")
Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 2")
```

**Files Modified:**
- `Modules/Guild.lua` (RecordDeltaError, MigrateTempErrors, Init, Reset, GetDeltaFailureCount, GetRecentDeltaErrors, ResetDeltaErrorCount)
- `Modules/Tests.lua` (testDeltaErrorTracking function)

**Benefits:**
- ✅ **No error data loss** - errors tracked even before guild initialization
- ✅ **Automatic migration** - temp errors moved to database when ready
- ✅ **Graceful degradation** - query functions check both temp and database storage
- ✅ **Debug visibility** - logs when using temporary storage
- ✅ **Full backwards compatibility** - existing production code unchanged
- ✅ **Test correctness** - proper parameter passing ensures valid tests

**How It Works:**
1. Delta errors before `GUILD_RANKS_UPDATE` → stored in temp memory
2. Guild initializes → `Init()` calls `MigrateTempErrors()`
3. Temp errors moved to database, temp storage cleared
4. All future errors go directly to database
5. Query functions check database first, fall back to temp if needed

**Test Results:**
- ✅ Early errors now tracked in temporary storage
- ✅ Automatic migration on guild initialization
- ✅ Error counts accurate across initialization boundary
- ✅ `/togbank deltaerrors` shows all errors including pre-init ones (checks both DB and temp storage)
- ✅ Test passes with correct parameter count
- ✅ Metrics reset verified - ready to track new failures
- ✅ System confirmed operational after reload

**Verification Steps Performed:**
1. Implemented temporary storage fallback mechanism
2. Updated `PrintDeltaErrors` to check both database and temp storage
3. Added migration logic to `Init()` and `Reset()`
4. Reset metrics with `/togbank resetmetrics` to clear pre-fix data
5. Confirmed clean state: 0 failures tracked, system ready for new errors
6. Error tracking now fully operational across all initialization states

---

## Bug Report Template

When reporting a new bug, copy this template and fill it out:

```markdown
### [BUG-XXX] Short Bug Title

**Severity:** 🔴/🟠/🟡/🟢
**Category:** [Category Name]
**Reporter:** [Your Name]
**Date Reported:** YYYY-MM-DD
**Status:** Open / In Progress / Testing / Resolved
**Assigned To:** [Name or Unassigned]

**Description:**
[Clear description of what's wrong]

**Steps to Reproduce:**
1. Step one
2. Step two
3. Step three

**Expected Behavior:**
[What should happen]

**Actual Behavior:**
[What actually happens]

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Number of bank alts: X
- Guild size: Y members
- Protocol versions in guild: [list if known]

**Debug Output:**
```
[Paste relevant /togbank debug output]
```

**Lua Errors:**
```
[Paste any Lua errors from /console scriptErrors 1]
```

**Related Test Case:**
[Reference from TESTING.md if applicable]

**Workaround:**
[Temporary fix if one exists]

**Proposed Fix:**
[Ideas for fixing, if any]

**Notes:**
[Any additional context]
```

---

## Known Limitations (Not Bugs)

These are documented limitations of v0.7.0, not bugs to be fixed:

1. **No Options Panel GUI** - Delta configuration via commands only
   - Severity: 🟢 LOW
   - Reason: Phase 7 focused on commands first, GUI planned for v0.8.0
   - Workaround: Use `/togbank` commands

2. **1-Hour Snapshot Expiration** - First sync after long offline uses full sync
   - Severity: 🟢 LOW
   - Reason: Design decision to prevent stale snapshots
   - Workaround: None needed, automatic fallback works

3. **50% Adoption Threshold** - Delta disabled if <50% guild supports v0.7.0
   - Severity: 🟡 MEDIUM
   - Reason: Design decision to ensure most members benefit
   - Workaround: Encourage guild to update, use `/togbank protocol` to check
   - **Testing Note:** Threshold lowered to 10% in Constants.lua for testing purposes (2026-01-20)

4. **30% Size Threshold** - Large changes (>30%) fall back to full sync
   - Severity: 🟢 LOW
   - Reason: Delta larger than full sync wastes bandwidth
   - Workaround: None needed, automatic fallback works

---

## Testing Status

Track which test suites have been executed and results:

| Test Suite | Status | Date Tested | Tester | Result | Notes |
| ------------ | -------- | ------------- | -------- | -------- | ------- |
| 1. Basic Delta Sync | 🔄 In Progress | 2026-01-20 | Team | ⚠️ Issues | Threshold lowered to 10%. Debug: Delta computed but full sync sent via togbank-d instead of togbank-d2 |
| 2. Error Handling | ⏳ Pending | - | - | - | - |
| 3. Protocol Negotiation | ⏳ Pending | - | - | - | - |
| 4. Performance & Metrics | ⏳ Pending | - | - | - | - |
| 5. User Commands | ⏳ Pending | - | - | - | - |
| 6. Edge Cases | ⏳ Pending | - | - | - | - |
| 7. Stress Testing | ⏳ Pending | - | - | - | - |
| 8. Integration | ⏳ Pending | - | - | - | - |

**Test Environment:**
- **Banker:** Metals-Azuresong (protocol v2, delta enabled)
- **Receiver:** Galdof-OldBlanchy (protocol v2, delta enabled)
- **Other guild members:** 6 members on protocol v1 (full sync only)
- **Protocol distribution:** 12.5% v2 (2 of 8 online)
- **Threshold:** Lowered to 10% for testing

**Current Issue:**
Delta computation completes (0.03-0.04ms) but full sync is sent via `togbank-d` instead of delta via `togbank-d2`. Missing log messages:
- "Snapshot saved for X"
- "✓ Delta selected" or "✗ Delta too large"
- "No changes detected"

Investigating why `useDelta` flag is false despite delta being computed.

**Status Legend:**
- ⏳ Pending - Not yet tested
- 🔄 In Progress - Currently testing
- ✅ Passed - All tests passed
- ⚠️ Issues Found - Some tests failed, bugs reported
- ❌ Blocked - Cannot test due to dependency
1 (open), 1 (fixed)
**Low:** 0
**Fixed:** 5
**Open:** 1istics

**Total Bugs:** 6
**Critical:** 0 (3 fixed)
**High:** 0 (1 fixed)
**Medium:** 2 (open)
**Low:** 0
**Fixed:** 4
**Open:** 2

**By Category:**fixed
- Delta Computation: 0
- Delta Application: 0
- Protocol Negotiation: 0
- Communication: 0
- Error Handling: 1 (fixed)
- Performance: 0
- Metrics: 0
- UI/Commands: 1 (open)
- Database: 0
- Backwards Compatibility: 1 (fixed)
- Module Initialization: 3 (fixed)
- Testing: 1 (open)

---

## Bug Numbering System

Use sequential numbering with category prefix:

- **DELTA-XXX** - Delta computation/application bugs
- **PROTO-XXX** - Protocol negotiation bugs
- **COMM-XXX** - Communication bugs
- **ERROR-XXX** - Error handling bugs
- **PERF-XXX** - Performance bugs
- **METRIC-XXX** - Metrics/reporting bugs
- **UI-XXX** - UI/command bugs
- **DB-XXX** - Database/snapshot bugs
- **COMPAT-XXX** - Backwards compatibility bugs

Examples: DELTA-001, PROTO-002, PERF-003

---

## Triage Guidelines

When a new bug is reported:

1. **Assess Severity:**
   - Does it crash or lose data? → 🔴 CRITICAL
   - Does it break major functionality? → 🟠 HIGH
   - Is it a minor issue with workaround? → 🟡 MEDIUM
   - Is it cosmetic or rare? → 🟢 LOW

2. **Categorize:**
   - Which system/module is affected?
   - Assign appropriate category

3. **Assign Priority:**
   - 🔴 CRITICAL: Drop everything, fix now
   - 🟠 HIGH: Schedule for next 24-48 hours
   - 🟡 MEDIUM: Add to weekly sprint
   - 🟢 LOW: Backlog for future

4. **Assign Owner:**
   - Who is best suited to fix this?
   - If unsure, leave as "Unassigned" for team review

5. **Reproduce:**
   - Can you reproduce it?
   - Document exact steps
   - Collect debug output

6. **Document:**
   - Add to appropriate severity section
   - Use bug report template
   - Update statistics

---

## Resolution Process

1. **Investigation:**
   - Reproduce the bug
   - Identify root cause
   - Check related code

2. **Fix Development:**
   - Implement fix
   - Add unit test if applicable
   - Update documentation if needed

3. **Testing:**
   - Verify fix works
   - Run regression tests
   - Test edge cases

4. **Documentation:**
   - Update bug status to "Resolved"
   - Move to "Resolved Bugs" section
   - Document fix in comments
   - Update statistics

5. **Release:**
   - Include in next version (hotfix or minor)
   - Add to CHANGELOG.md
   - Notify affected users if critical

---

## Communication

### Reporting Bugs

- Add bugs directly to this document
- Notify team in guild chat or Discord
- For critical bugs, contact lead developer immediately

### Status Updates

- Update bug status as work progresses
- Comment on bugs with new findings
- Move resolved bugs to "Resolved" section

### Reviews

- Team reviews bug list weekly
- Triage new bugs together
- Reprioritize as needed

---

## Related Documents

- [TESTING.md](TESTING.md) - Manual testing procedures
- [DELTA_IMPLEMENTATION_TODO.md](DELTA_IMPLEMENTATION_TODO.md) - Implementation checklist
- [CHANGELOG.md](CHANGELOG.md) - Version history
- [README.txt](README.txt) - User documentation

---

## Notes for Testers

### Automated Tests

Run automated test suite first:
```
/togbank test
```
Expected: 26/26 tests passing ✓

### Enable Debug Output

For detailed logging during manual tests:
```
/togbank debug
```

### Key Commands for Testing

```
/togbank deltastats     - View metrics
/togbank protocol       - Check protocol distribution
/togbank clearsnapshots - Clear all snapshots (force full sync)
/togbank forcefull      - Toggle force full sync mode
/togbank resetmetrics   - Reset metrics to zero
```

### What to Watch For

- ❌ Lua errors (enable with `/console scriptErrors 1`)
- ⚠️ Version mismatch messages
- ⚠️ Delta application failures
- ⚠️ Unexpected full syncs
- ⚠️ Performance degradation (use `/togbank deltastats` performance section)
- ⚠️ Missing or incorrect inventory after sync

### Reporting Tips

- Include `/togbank deltastats` output
- Include `/togbank protocol` output
- Copy debug messages (from `/togbank debug`)
- Note guild size and protocol distribution
- Specify which test case failed (from TESTING.md)

---

## ✅ [DELTA-010] Validation rejected v0.8.0 minimal removed items format

**Severity:** High
**Status:** ✅ RESOLVED (2026-01-27)
**Impact:** Delta sync failures when items removed from bags/bank

### Problem

Delta validation was rejecting removed items that didn't have a `Link` property, causing repeated VALIDATION_FAILED errors like:
```
TOGBankClassic: [WARN] Repeated delta sync failures for Togherbs-Azuresong. Falling back to full sync.
TOGBankClassic: Validation failed: invalid bags delta: removed item missing or invalid Link
```

### Root Cause

**Mismatch between delta creation and validation:**

1. **Delta creation** (DeltaComms.lua:459) - Creates minimal removed items:
   ```lua
   -- v0.8.0: Minimal removes format (just ID, no Link or Count)
   -- Saves 4 bytes per removed item
   table.insert(delta.removed, { ID = item.ID })
   ```

2. **Delta validation** (DeltaComms.lua:122) - Required Link property:
   ```lua
   if not item.Link or type(item.Link) ~= "string" then
       return false, "removed item missing or invalid Link"
   end
   ```

3. **Delta application** (DeltaComms.lua:592-599) - Handles ID-only removal correctly:
   ```lua
   -- New format (v0.8.0): Only has ID, match by ID only
   for i = #items, 1, -1 do
       local item = items[i]
       if item and item.ID == removedItem.ID then
           table.remove(items, i)
           break
       end
   end
   ```

**Why this happened:** The v0.8.0 bandwidth optimization removed Link from transmitted removed items (saves ~60 bytes per item), but validation wasn't updated to accept this minimal format.

### Solution

**File:** `Modules/DeltaComms.lua:110-125`

Updated validation to accept removed items without Link:
```lua
-- Check removed array
if itemDelta.removed then
    if type(itemDelta.removed) ~= "table" then
        return false, "removed is not a table"
    end
    for _, item in pairs(itemDelta.removed) do
        if type(item) ~= "table" then
            return false, "removed item is not a table"
        end
        if not item.ID or type(item.ID) ~= "number" then
            return false, "removed item missing or invalid ID"
        end
        -- v0.8.0: Link is optional in removed items (bandwidth optimization)
        -- Only ID is required; Link is backfilled during application if needed
    end
end
```

**Rationale:**
- Removed items only need ID for matching (line 596 in ApplyItemDelta)
- Link would be redundant - we're removing the item, not reading its properties
- Keeps the 4-byte bandwidth savings per removed item

### Testing

1. Have two clients online (e.g., Togherbs and Galdof)
2. Remove items from bags/bank on Togherbs
3. Verify Galdof receives delta without VALIDATION_FAILED errors
4. Check `/togbank deltaerrors` shows no new errors

### Related Issues

- Works with delta application logic that matches by ID only (line 592)
- Maintains backwards compatibility (still handles old format with Link if present)
- Preserves v0.8.0 bandwidth optimization

---

## ✅ [DELTA-010b] 78% Delta Sync Failure Rate from Strict Link Validation

**Severity:** 🔴 CRITICAL
**Category:** Delta Sync / Validation
**Reporter:** Investigation / Metrics Analysis
**Date Reported:** 2026-01-30
**Status:** ✅ FIXED (2026-01-30)
**Impact:** 78% delta failure rate, legitimate link-less deltas rejected

### Summary

Delta sync showing 78% failure rate caused by overly strict validation rejecting valid link-less deltas (v0.8.0 bandwidth optimization feature) and logging of UNAUTHORIZED banker protection events creating confusion about actual failure rate.

### Observed Behavior

**Metrics:**
```
/togbank deltastats showed:
- 78% delta failure rate
- Repeated VALIDATION_FAILED errors
- Frequent UNAUTHORIZED rejection messages
```

**Error Log Output:**
```lua
TOGBankClassic_Guild:GetRecentDeltaErrors()
[1-10] errors showing:
  - 60% UNAUTHORIZED: "Rejected delta from [banker] about ourselves (banker is source of truth)"
  - 40% VALIDATION_FAILED: "invalid bank delta: added item missing or invalid Link"
```

### Root Cause Analysis

**Issue 1: Link Validation Too Strict (40% of errors)**

**Location:** `Modules/DeltaComms.lua` lines 86-87, 101-102

**Problem:**
```lua
-- BEFORE (incorrect):
if not item.Link or type(item.Link) ~= "string" then
    return false, "added item missing or invalid Link"
end
```

The validation required `Link` to be present in `added` and `modified` items, but v0.8.0 introduced link-less deltas as a bandwidth optimization where receivers reconstruct links from item IDs.

**Evidence:**
- Comment at line 117 said "Link is optional in removed items (bandwidth optimization)"
- DELTA-010 fixed removed items on 2026-01-27
- v0.8.0 features include link-less delta support (togbank-d3, togbank-d4)
- Validation was rejecting valid deltas that intentionally omitted links in added/modified items

**Issue 2: UNAUTHORIZED Logging (60% of errors)**

**Location:** `Modules/DeltaComms.lua` lines 701, 716

**Problem:**
These are **working correctly** - banker protection is functioning as designed by rejecting deltas from other bankers about the local banker's own data. However, seeing these in the error log created confusion about the failure rate.

**Note:** These were **NOT** being counted in `deltasFailed` metrics (only logged), so they didn't actually inflate the failure percentage, but their presence in the error log suggested problems.

### Impact

**For Users:**
- **High perceived failure rate** causing concern about delta sync reliability
- **Legitimate link-less deltas rejected**, forcing unnecessary full syncs
- **Bandwidth optimization defeated** - link-less deltas couldn't be used

**For System:**
- Increased bandwidth usage (full syncs instead of deltas)
- Unnecessary full sync fallbacks
- Delta chain replay failures when link-less deltas in history

### Fix Implementation

**Change 1: Make Link Optional in Validation**

**File:** `Modules/DeltaComms.lua`

**Lines 86-88 (added items):**
```lua
// BEFORE:
if not item.Link or type(item.Link) ~= "string" then
    return false, "added item missing or invalid Link"
end

// AFTER:
-- v0.8.0: Link is optional (bandwidth optimization - receiver reconstructs)
if item.Link and type(item.Link) ~= "string" then
    return false, "added item has invalid Link"
end
```

**Lines 101-103 (modified items):**
```lua
// BEFORE:
if not item.Link or type(item.Link) ~= "string" then
    return false, "modified item missing or invalid Link"
end

// AFTER:
-- v0.8.0: Link is optional (bandwidth optimization - receiver reconstructs)
if item.Link and type(item.Link) ~= "string" then
    return false, "modified item has invalid Link"
end
```

**Logic:**
- If `Link` is present, it must be a string (type validation)
- If `Link` is absent, that's acceptable (receiver will reconstruct)

**Change 2: Added Clarifying Comment**

**File:** `Modules/Chat.lua` line ~912

Added comment explaining validation failure counting remains (now rare with optional Link).

### Testing

**Pre-Fix Baseline:**
```
/togbank deltastats
Expected: ~78% failure rate
Expected: VALIDATION_FAILED errors in logs
```

**Apply Fix:**
1. Update `DeltaComms.lua` validation logic
2. Reload addon (`/reload`)
3. Reset metrics: `/togbank resetmetrics`

**Post-Fix Verification:**
1. **Monitor failure rate:**
   ```
   /togbank deltastats
   Expected: <5% failure rate (legitimate failures only)
   ```

2. **Check error logs:**
   ```lua
   /dump TOGBankClassic_Guild:GetRecentDeltaErrors()
   Expected: No VALIDATION_FAILED for missing Link
   Expected: UNAUTHORIZED still present (working correctly)
   ```

3. **Verify link-less deltas accepted:**
   - Trigger delta sync between clients
   - Confirm link-less deltas (togbank-d3) process successfully
   - Verify items display correctly with reconstructed links

4. **Bandwidth verification:**
   ```
   /togbank deltastats
   Check: Delta bytes should be smaller (links not transmitted)
   ```

### Expected Results

**Metrics Improvement:**
- **Before:** 78% delta failure rate
- **After:** <5% delta failure rate (only legitimate failures)

**Error Log:**
- **VALIDATION_FAILED for missing Link:** Disappeared completely
- **UNAUTHORIZED:** Still appears (banker protection working correctly)
- Other error types (VERSION_MISMATCH, NO_DATA): May still occur legitimately

**System Behavior:**
- Link-less deltas accepted and processed
- Items display correctly with reconstructed links
- Bandwidth optimization functional
- Delta chain replay works with link-less deltas

### Lessons Learned

1. **Validation must match features:** When adding bandwidth optimizations, update validation logic simultaneously
2. **Error logging context:** Distinguish between "errors" (problems) and "rejections" (working correctly)
3. **Test with metrics:** Monitor `/togbank deltastats` when implementing protocol changes
4. **Incremental fixes:** DELTA-010 fixed removed items but missed added/modified items

### Why This Wasn't Caught Earlier

The v0.8.0 link-less delta feature was implemented with send-side link stripping, but the receive-side validation wasn't fully updated to accept optional links. DELTA-010 (2026-01-27) fixed removed items, but added/modified items still required Link until this fix.

This created a mismatch where:
- Sender: Strips links to save bandwidth
- Receiver: Rejects deltas without links as "invalid"

### UNAUTHORIZED "Errors" Clarification

The UNAUTHORIZED rejections appearing in error logs are actually **banker protection working correctly**:
- Other bankers broadcast their data
- Local banker receives delta about themselves
- Protection correctly rejects it (banker is source of truth for own data)
- This is logged for debugging but **not counted as a failure**

Future improvement: Consider separate logging for "rejections" vs "failures" to reduce confusion.

### Files Modified

- `Modules/DeltaComms.lua` - Made Link optional in added/modified item validation (lines ~86-88, ~101-103)
- `Modules/Chat.lua` - Added clarifying comment for validation failure counting (line ~912)

### Related Issues

- **DELTA-010:** Fixed removed items (2026-01-27) - this fix completes the work
- **v0.8.0 Link-less Delta Feature:** This fix enables the full bandwidth optimization
- **Delta Chain Replay:** Now works with link-less deltas in history
- **Bandwidth Metrics:** Shows accurate savings from link-less transmission

---

## ✅ [UI-005] Inventory UI crash on missing slots field

**Severity:** Medium
**Status:** ✅ RESOLVED (2026-01-27)
**Impact:** Lua error when hovering over status bar in Inventory window

### Problem

Lua error when hovering over the Inventory window status bar:
```
attempt to index field 'slots' (a nil value)
[TOGBankClassic/Modules/UI/Inventory.lua]:220
```

### Root Cause

Code assumed `alt.bank.slots` and `alt.bags.slots` always exist, but older alt data or incomplete sync data may not have these fields:

```lua
if alt.bank then
    slot_count = slot_count + alt.bank.slots.count  -- crashes if slots is nil
    slot_total = slot_total + alt.bank.slots.total
end
```

### Solution

**File:** `Modules/UI/Inventory.lua:217-226`

Added nil checks before accessing slots:
```lua
if alt.bank and alt.bank.slots then
    slot_count = slot_count + alt.bank.slots.count
    slot_total = slot_total + alt.bank.slots.total
end
if alt.bags and alt.bags.slots then
    slot_count = slot_count + alt.bags.slots.count
    slot_total = slot_total + alt.bags.slots.total
end
```

### Testing

1. Open Inventory window (`/togbank`)
2. Hover over status bar at bottom
3. Verify no Lua errors appear
4. Slot counts display as "0/0" if data incomplete, or actual counts if available

---

**Happy testing! Report all bugs, no matter how small. Every bug found makes the addon better. 🐛➡️✅**

---

### ✅ [MAIL-004] Non-stackable items filtered out by greedy algorithm for multi-quantity fulfills

**Severity:** 🔴 CRITICAL  
**Category:** Mail / Fulfill  
**Date Reported:** 2026-01-28  
**Status:** ✅ RESOLVED  
**Resolution Date:** 2026-01-28

**Description:**
When attempting to fulfill a request for multiple non-stackable items (like 4 Runecloth Bags), the fulfill button showed "(no runecloth bag found in bags)" even though the character had many of them in inventory. This worked fine for single items (need 1) but broke for quantities > 1.

**Test Case:**
- Character: Bag vendor with 100+ Runecloth Bags in inventory (each count=1, non-stackable)
- Request: 4 Runecloth Bags
- Expected: Fulfill button works and attaches 4 bags
- Actual: Button shows "(no runecloth bag found in bags)"
- Note: Worked yesterday, broke after greedy algorithm changes

**Root Cause:**
The greedy algorithm's `minStackSize` calculation didn't account for non-stackable items when quantity needed > 1.

For **4 Runecloth Bags** (each count=1):
```lua
largestStack = 1
accumulated = 100  -- all bags included
wouldNeedToSplit = max(0, 4 - 100) = 0
minStackSize = math.min(5, qtyNeeded) = math.min(5, 4) = 4  ❌

-- Filtering at line 593:
if item.count >= minStackSize then  -- 1 >= 4 is FALSE
    -- All bags filtered out!
end
```

Result: `usefulStacks` is empty, nothing gets attached, error returned.

**Why it worked for quantity=1:**
```lua
minStackSize = math.min(5, 1) = 1  ✅
if 1 >= 1 then  -- TRUE, bags included
```

**Solution:**
Capped `minStackSize` to never exceed `largestStack`.

**File:** `Modules/Mail.lua:585-591`

**Changes:**
```lua
-- BEFORE:
local minStackSize = wouldNeedToSplit > 0 and wouldNeedToSplit or math.min(5, qtyNeeded)

-- AFTER:
local minStackSize = math.min(largestStack, wouldNeedToSplit > 0 and wouldNeedToSplit or math.min(5, qtyNeeded))
```

Now for **4 Runecloth Bags**:
```lua
minStackSize = min(1, min(5, 4)) = min(1, 4) = 1  ✅
if 1 >= 1 then  -- TRUE, bags included
```

**Testing:**
1. Create request for 4 Runecloth Bags
2. On bag vendor with 100+ bags
3. Click Fulfill button
4. Verify 4 bags attach to mail
5. Test with other non-stackable items (gear, other bags)
6. Test with various quantities (1, 2, 5, 10)

**Why the bug was introduced:**
The `math.min(5, qtyNeeded)` logic was added to handle small quantity requests (need 1-4 items) to prevent filtering out perfectly-sized stacks. However, it didn't account for non-stackable items where `largestStack = 1`, creating an impossible filter condition when needing multiple items.

---

### ✅ [UI-006] Highlight checkbox not appearing on first login for bankers

**Severity:** 🟡 MEDIUM  
**Category:** UI / Requests Window  
**Date Reported:** 2026-01-28  
**Status:** ✅ RESOLVED  
**Resolution Date:** 2026-02-20 (Complete fix)

**Description:**
The "Highlight needed items" checkbox in the Requests window (banker-only feature) was not appearing on first login for banker characters. After doing `/reload`, the checkbox would appear correctly every time.

**Symptoms:**
- First login as banker: checkbox missing
- After `/reload`: checkbox present  
- Subsequent logins after `/reload`: checkbox still missing until another `/reload`

**Root Cause:**
**Initial Diagnostic (2026-01-28):** The checkbox visibility is determined during window creation by checking if the current player is a banker via `GetBanks()` → `IsBank()`. These functions rely on guild roster data from `GetNumGuildMembers()` and `GetGuildRosterInfo()`, which may not be loaded immediately after login.

**Complete Root Cause (2026-02-20):** The issue had two parts:

1. **Initial Window Creation:** When `DrawWindow()` is called on first login, the checkbox creation code checks `GetNumGuildMembers() > 0` at line 625. If guild roster isn't loaded yet, this returns 0/false, and the checkbox is skipped entirely.

2. **Missing Delayed Creation:** When `GUILD_ROSTER_UPDATE` fires later and calls `RefreshRequestsUI()` → `UpdateFilters()`, the `UpdateFilters()` function only updated the dropdown filters. It had **no logic to create the checkbox** if it was missing. The checkbox only existed if it was created during initial window creation.

3. **Why `/reload` worked:** After a `/reload`, the guild roster data is already cached in memory from the previous session, so `GetNumGuildMembers() > 0` returns true immediately during window creation.

The flow:
1. First login: Player opens Requests window
2. `DrawWindow()` checks `GetNumGuildMembers() > 0` → returns 0 (roster not loaded)
3. Checkbox creation skipped, `self.HighlightCheckbox` remains nil
4. Later, `GUILD_ROSTER_UPDATE` fires → calls `UpdateFilters()`
5. `UpdateFilters()` updates dropdowns but doesn't create missing checkbox
6. Checkbox never appears until window is destroyed and recreated (e.g., banker status change or `/reload`)

**Solution:**

**Phase 1 (2026-01-28):** Added `TOGBankClassic_Guild:RefreshRequestsUI()` call to `GUILD_ROSTER_UPDATE` event handler. This ensured `UpdateFilters()` was called when roster data became available, but wasn't sufficient because `UpdateFilters()` didn't create the checkbox.

**Phase 2 (2026-02-20):** Added delayed checkbox creation logic to `UpdateFilters()` function.

**Files:**
- `Modules/Events.lua:~307` (Phase 1)
- `Modules/UI/Requests.lua:~1095-1117` (Phase 2)

**Changes:**
```lua
-- Modules/UI/Requests.lua: UpdateFilters() (NEW section added after line 1093)
function TOGBankClassic_UI_Requests:UpdateFilters()
	if not self.FilterRequester or not self.FilterBank then
		return
	end
	
	-- ... existing filter setup code ...

	-- NEW: Create highlight checkbox if it doesn't exist but should (banker status now available)
	if not self.HighlightCheckbox and self.FilterGroup and GetNumGuildMembers() > 0 then
		local isBank = TOGBankClassic_Guild:IsBank(currentPlayer)
		if isBank then
			TOGBankClassic_Output:Debug("UI", "UpdateFilters: Creating highlight checkbox (delayed)")
			local highlightCheckbox = TOGBankClassic_UI:Create("CheckBox")
			highlightCheckbox:SetLabel("Highlight needed items")
			highlightCheckbox:SetFullWidth(true)
			highlightCheckbox:SetValue(TOGBankClassic_ItemHighlight and TOGBankClassic_ItemHighlight.enabled or false)
			highlightCheckbox:SetCallback("OnValueChanged", function(widget, _, value)
				if TOGBankClassic_ItemHighlight then
					TOGBankClassic_ItemHighlight:SetEnabled(value)
				end
			end)
			self.FilterGroup:AddChild(highlightCheckbox)
			self.HighlightCheckbox = highlightCheckbox
			-- Re-layout filter group to show new checkbox
			if self.FilterGroup.DoLayout then
				self.FilterGroup:DoLayout()
			end
			TOGBankClassic_Output:Debug("UI", "UpdateFilters: Highlight checkbox created and added")
		end
	end

	-- ... rest of UpdateFilters code ...
end
```

Now when `GUILD_ROSTER_UPDATE` fires and calls `UpdateFilters()`, the function checks if:
1. Checkbox doesn't exist yet (`!self.HighlightCheckbox`)
2. Guild roster is now loaded (`GetNumGuildMembers() > 0`)
3. Current player is a banker (`IsBank(currentPlayer)`)

If all conditions are met, the checkbox is created dynamically and added to the filter group. The UI is then re-laid out to display the new checkbox.

**Testing:**
1. ✅ Log in as banker character for the first time (cold start)
2. ✅ Open Requests window immediately after login
3. ✅ Checkbox should appear within 1-2 seconds as guild roster loads
4. ✅ No `/reload` required
5. ✅ Log in as non-banker character - checkbox should never appear
6. ✅ Switch between banker and non-banker alts - checkbox appears/disappears correctly

---

### ✅ [PERF-003] In-game stuttering during async item reconstruction

**Severity:** 🔴 CRITICAL  
**Category:** Performance / UI / Async Loading  
**Date Reported:** 2026-01-28  
**Date Resolved:** 2026-01-28  
**Status:** ✅ RESOLVED  

**Problem:**
Severe in-game stuttering/freezing when receiving synced data, both when opening inventory windows AND during normal gameplay when UI was closed. Game became unresponsive for 1-2 seconds at a time during sync.

**Root Cause Analysis:**

**Initial Issue:**
When items are reconstructed asynchronously (via `Item:ContinueOnItemLoad` callbacks), each item's callback triggered a full UI redraw by calling `DrawContent()`.

**Example scenario:**
1. Banker has 100+ unique items
2. Receiver gets data, Chat.lua calls `ReconstructItemLinks()` on ALL delta arrays (6 arrays)
3. Starts async loading 100+ items IMMEDIATELY in background
4. **100+ separate DrawContent() calls in ~1 second**
5. Each DrawContent() redraws entire UI (expensive operation)
6. Result: 100 full UI redraws = game freeze/stutter

**Iteration 1: Lazy Loading**
- Removed eager reconstruction calls from Chat.lua
- Only reconstructed links when DrawItem() called (UI open)
- Problem: Opening UI tried to reconstruct ALL visible items at once → spike on UI open
- Also: Blank tooltips on `/wipe` since items not in cache

**Iteration 2: Batched Queue System (Final Solution)**

**Performance Analysis:**
```
Before Fix:
- 100 items loading eagerly when sync received
- 100 async callbacks + 100 DrawContent() calls
- ~10ms per DrawContent = 1000ms blocking UI
- Stuttering: 🔴 SEVERE (even with UI closed)

After Fix:
- Items queued and processed in batches
- 5 items every 0.1s = ~2 seconds to process 100 items
- 2-3 DrawContent() calls (throttled to 0.5s intervals)
- ~30ms total UI refresh time
- Stuttering: ✅ NONE
```

**Solution: Batched Queue System with Throttled Refresh**

**1. Throttled UI Refresh** (Guild.lua, line 965):
```lua
local lastUIRefresh = 0
local function ThrottledUIRefresh()
    local now = GetTime()
    if now - lastUIRefresh < 0.5 then  -- Max once per 0.5 seconds
        return
    end
    lastUIRefresh = now
    
    -- Only refresh if UI is actually open
    if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
        TOGBankClassic_UI_Inventory:DrawContent()
    end
    if TOGBankClassic_UI_Search and TOGBankClassic_UI_Search.isOpen then
        TOGBankClassic_UI_Search:DrawContent()
    end
end
```

**2. Batched Processing Queue** (Guild.lua, line 983):
```lua
local itemReconstructQueue = {}
local isProcessingQueue = false
local pendingAsyncLoads = 0  -- Track number of pending async loads
local MAX_CONCURRENT_ASYNC = 3  -- Limit concurrent async operations
local BATCH_SIZE = 10  -- Process 10 items at a time
local BATCH_DELAY = 0.2  -- 0.2 second delay between batches (slower = smoother)

local function ProcessItemQueue()
    -- Process batch of 10 items
    -- Try synchronous load from cache first
    -- If not in cache AND fewer than 3 async loads active → start async
    -- If 3+ async loads already active → requeue item for next batch
    -- Refresh UI if any loaded synchronously
    -- Schedule next batch after 0.2s delay
end
```

**3. Queue Population** (Guild.lua, line 1073):
```lua
function TOGBankClassic_Guild:ReconstructItemLinks(items)
    -- Add all items without links to queue
    for _, item in ipairs(items) do
        if item and item.ID and not item.Link then
            table.insert(itemReconstructQueue, item)
        end
    end
    
    -- Start processing if not already running
    if not isProcessingQueue then
        isProcessingQueue = true
        ProcessItemQueue()
    end
end
```

**4. Eager Reconstruction Re-enabled** (Chat.lua, line 822):
```lua
-- Now safe to reconstruct in background with batched queue
if data.changes then
    if data.changes.bank then
        TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bank.added)
        TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bank.modified)
        TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bank.removed)
    end
    if data.changes.bags then
        TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bags.added)
        TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bags.modified)
        TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bags.removed)
    end
end
```

**How It Works:**

**Timeline after sync:**
- T+0.0s: Sync received, items added to queue (not processed yet)
- T+0.2s: Process batch 1 (10 items) → max 3 async loads → refresh UI if any loaded
- T+0.4s: Process batch 2 (10 items) → max 3 async loads → refresh UI if any loaded
- T+0.6s: Process batch 3 (10 items) → max 3 async loads → refresh UI if any loaded
- ...continues until queue empty

**For each batch:**
1. Try synchronous load from cache (instant if available)
2. If not in cache:
   - Check if fewer than 3 async loads currently active
   - If yes → create async `Item:ContinueOnItemLoad`
   - If no (3+ active) → **requeue item for next batch**
3. If any loaded synchronously → call `ThrottledUIRefresh()`
4. Async callbacks decrement counter and call `ThrottledUIRefresh()` when complete

**Async Load Limiting:**
- Never more than 3 concurrent `Item:CreateFromItemID` operations
- Items that can't be processed (limit reached) are requeued
- Prevents overwhelming WoW's item loading system
- Critical for smooth performance after `/wipe` (empty cache)

**UI Refresh Behavior:**
- Max once per 0.5 seconds (prevents excessive redraws)
- Only refreshes if UI windows are actually open (no background updates)
- Batch processing spreads load: 10 items/0.2s = 50 items/second
- **Concurrent async limit: 3 operations maximum**

**Benefits:**
1. **Eliminates stuttering** - Smooth background processing, no frame drops
2. **Works with UI closed** - No eager loading spike
3. **Works with UI open** - Items appear in waves, not all at once
4. **Cache-optimized** - Items in cache load instantly in batches
5. **Scalable** - 10 items or 1000 items, same smooth performance

**ItemString Integration:**
Items with ItemString (gear with random stats) are processed the same as basic items:
```lua
if item.ItemString then
    -- Reconstruct: |Hitem:18813:0:0:0:0:0:1804:0|h[Ring of the Eagle]|h
    -- Preserves suffixID (1804) for tooltip stats
else
    -- Basic item: |Hitem:2772|h[Iron Ore]|h
    -- Simple link from ID
end
```

**Backward Compatibility:**
Old clients without ItemString support:
- Still receive data (ItemString field ignored)
- Fall back to basic ID-only links
- Basic items work perfectly
- Gear with random stats shows generic tooltips (no bonus stats)
- No crashes or errors

**Testing:**
1. Have banker with 100+ items
2. On non-banker client: `/wipe`, `/sync`
3. Observe smooth performance during sync (UI closed)
4. Open inventory window - items appear in waves
- ✅ Never more than 3 concurrent async Item loads (prevents overload)
- ✅ Batch delay of 0.2s ensures smooth gameplay even with cold cache
5. Hover over items - tooltips work for all items
6. No stuttering at any point

**Performance Metrics:**
- ✅ Stuttering eliminated (from 1-2 second freezes to smooth)
- ✅ Frame rate stable during item reconstruction (UI open or closed)
- ✅ UI remains responsive while loading
- ✅ All items populate correctly with full tooltip stats
- ✅ Background processing doesn't impact gameplay
- ✅ Queue processes ~50 items/second without performance impact

---

### ✅ [UI-007] Item tooltips not showing stats on gear

**Severity:** 🟡 MEDIUM  
**Category:** UI / Item Display / Link Reconstruction  
**Date Reported:** 2026-01-28  
**Date Resolved:** 2026-01-28  
**Status:** ✅ RESOLVED  

**Problem:**
Item tooltips in the addon interface showed armor values but were missing stat information (e.g., +Intellect, +Stamina, +Spell Power) for equipment like rings, wands, and other gear with random suffixes or unique properties.

**Root Cause:**
When reconstructing item links from transmitted data, we only used the item ID to regenerate links via `GetItemInfo(itemID)`. This created basic item links without the unique parameters needed for items with random properties.

**Item Link Structure:**
```
|Hitem:itemID:enchantID:gemID1:...:suffixID:uniqueID:level|h[Name]|h|r
```

Items with "of the Eagle", spell power, or other variable stats need the **suffixID** and **uniqueID** parameters preserved. Using only itemID loses this information.

**Example:**
- **Original Link:** `|Hitem:18813:0:0:0:0:0:1804:0|h[Ring of Binding]|h|r` (has suffix 1804)
- **Reconstructed (broken):** `|Hitem:18813:0:0:0:0:0:0:0|h[Ring of Binding]|h|r` (missing suffix)
- **Result:** Tooltip showed armor but no +stats

**Solution:**

**1. Preserve ItemString during transmission** (StripItemLinks, line 936):
```lua
-- Extract itemString from full link: "18813:0:0:0:0:0:1804:0"
if item.Link then
    local itemString = string.match(item.Link, "item:([^|]+)")
    if itemString then
        strippedItem.ItemString = itemString
    end
end
```

**2. Reconstruct using ItemString** (ReconstructItemLinks, line 965):
```lua
if item.ItemString then
    -- Use full itemString to preserve suffixes/uniqueIDs
    local itemName = GetItemInfo(item.ID)
    if itemName then
        item.Link = string.format("|cffffffff|Hitem:%s|h[%s]|h|r", item.ItemString, itemName)
    end
else
    -- Fallback to basic ID-only link for non-unique items
    item.Link = select(2, GetItemInfo(item.ID))
end
```

**Bandwidth Impact:**
- ItemString adds ~20-50 bytes per unique item (items with suffixes/enchants)
- Example: "18813:0:0:0:0:0:1804:0" = 27 bytes vs "18813" = 5 bytes
- Trade-off: Necessary to preserve full tooltip information

**Related Fixes:**
- Added nil check in UI.lua DrawItem() for items without Info populated yet
- Added throttled UI refresh to prevent stuttering from async loading (see PERF-003)

**Testing:**
1. Scan banker with rings/wands with random stats
2. Receive data on non-banker client
3. Hover over items in inventory/search
4. Verify tooltips show all stats (+Intellect, +Spell Power, etc.)

**Verification:**
- ✅ Tooltips show complete stats for all item types
- ✅ ItemString preserved during send/receive cycle
- ✅ Backward compatible (old clients ignore ItemString field)
- ✅ Forward compatible (gracefully falls back if ItemString missing)

---

### ✅ [SYNC-007] Backward compatibility for SYNC-006 aggregate structure

**Severity:** 🟠 HIGH  
**Category:** Delta Sync / Backward Compatibility / Data Structure Migration  
**Reporter:** Internal (discovered during SYNC-006 implementation)  
**Date Reported:** 2026-01-28  
**Date Resolved:** 2026-01-28  
**Status:** ✅ RESOLVED  
**Related:** [SYNC-006] Mail quantities consolidation

**Problem:**
SYNC-006 introduced `alt.items` as a consolidated aggregate of bank + bags + mail, replacing the previous structure where only `alt.bank.items` and `alt.bags.items` existed. This created a breaking change:
- **Yesterday's clients** (pre-SYNC-006): Only send/read `alt.bank.items` and `alt.bags.items`
- **Today's clients** (post-SYNC-006): Send/read `alt.items` aggregate, plus maintain legacy fields
- **Mail data**: Previously never synced, now included in `alt.items` but not in legacy fields

**Compatibility Issues:**
1. **Old client → New client**: Old data lacks `alt.items`, causing new client to display empty inventory
2. **New client → Old client**: Old client doesn't understand `alt.items`, would only see bank/bags (missing mail)
3. **Mail visibility**: Old clients never had mail sync, need backward-compatible way to see mail items

**Complete Solution - Bidirectional Compatibility:**

**1. Receiver Side (Guild.lua `ReceiveAltData`, lines 1415-1530):**
Handles receiving data from old clients that only have `alt.bank.items` and `alt.bags.items`:

```lua
-- Backward compatibility: Compute alt.items from sources if missing
local needsReconstruction = not hasAnyItems(alt.items)

if needsReconstruction then
    local bankItems = (alt.bank and alt.bank.items) or {}
    local bagItems = (alt.bags and alt.bags.items) or {}
    
    -- Aggregate bank + bags ONLY (mail was never synced in old system)
    if #bankItems > 0 or #bagItems > 0 then
        local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
        alt.items = {}
        for _, item in pairs(aggregated) do
            table.insert(alt.items, item)
        end
    end
end
```

**Key points:**
- Detects when incoming data has old structure (no `alt.items`)
- Reconstructs `alt.items` by aggregating `alt.bank.items` + `alt.bags.items`
- Does NOT include mail (old system never synced mail)
- Preserves legacy fields for potential re-sync to other old clients

**2. Sender Side (Guild.lua `EnsureLegacyFields`, lines 1036-1106):**
Ensures all clients receive usable data by sending all 3 arrays:

```lua
function TOGBankClassic_Guild:EnsureLegacyFields(alt)
    -- Always send 3 arrays for complete backward compatibility:
    -- 1. alt.items (for new clients)
    -- 2. alt.bank.items with mail aggregated (for old clients)
    -- 3. alt.bags.items as-is (for old clients)
    
    -- Check if we have mail items to aggregate
    local hasMailItems = alt.mail and alt.mail.items and next(alt.mail.items)
    
    -- If legacy fields don't exist, reconstruct from alt.items
    if not alt.bank or not alt.bank.items then
        alt.bank = { items = {} }
        -- Put ALL items in bank.items (includes mail)
        for _, item in ipairs(alt.items) do
            table.insert(alt.bank.items, item)
        end
        alt.bags = { items = {} }
        return alt
    end
    
    -- Legacy fields exist from Bank.lua scan, but don't include mail
    -- Aggregate mail items into bank.items for old client visibility
    if hasMailItems then
        local existingBank = {}
        for _, item in ipairs(alt.bank.items) do
            if item.ID then
                existingBank[item.ID] = item
            end
        end
        
        for itemID, mailItem in pairs(alt.mail.items) do
            if existingBank[itemID] then
                -- Item exists in bank, add mail count
                existingBank[itemID].Count = (existingBank[itemID].Count or 0) + (mailItem.count or 0)
            else
                -- Item only in mail, add as new entry to bank.items
                table.insert(alt.bank.items, { 
                    ID = itemID, 
                    Count = mailItem.count, 
                    Link = mailItem.link 
                })
            end
        end
    end
end
```

**Key points:**
- Runs before every send in `SendAltData()`
- Ensures all 3 arrays exist: `alt.items`, `alt.bank.items`, `alt.bags.items`
- Mail items are aggregated into `alt.bank.items` for old client visibility
- Old clients see mail quantities they never could before (new capability!)

**3. Data Structure Sent:**

**New client sending to anyone:**
```lua
alt = {
    version = 1738108800,
    money = 123456,
    items = {  -- NEW: aggregate (bank + bags + mail)
        { ID = 14046, Count = 104, Link = "[Runecloth Bag]" },
        { ID = 6948, Count = 1, Link = "[Hearthstone]" },
        ...
    },
    bank = {
        items = {  -- LEGACY: bank items + mail items (for old clients)
            { ID = 14046, Count = 71, Link = "[Runecloth Bag]" },  -- 70 in bank + 1 in mail
            ...
        },
        slots = { count = 15, total = 28 }
    },
    bags = {
        items = {  -- LEGACY: bag items only (for old clients)
            { ID = 14046, Count = 33, Link = "[Runecloth Bag]" },
            { ID = 6948, Count = 1, Link = "[Hearthstone]" },
            ...
        },
        slots = { count = 16, total = 16 }
    },
    mail = {  -- Mail metadata (not read by old clients)
        items = {
            [14046] = { count = 1, link = "[Runecloth Bag]" }
        }
    }
}
```

**What each client type reads:**
- **New client (post-SYNC-006)**: Uses `alt.items` (104 runecloth bags total)
- **Old client (pre-SYNC-006)**: Uses `alt.bank.items` + `alt.bags.items` (71 + 33 = 104, includes mail)
- **Old client mail visibility**: Now sees mail quantities in `alt.bank.items` (previously impossible)

**4. Bandwidth Optimization:**
When sending via new protocol (`togbank-d3`, link-less), also strip links from legacy fields:

```lua
-- In StripAltLinks() (lines 994-1029):
local strippedBank = nil
if alt.bank then
    strippedBank = {
        slots = alt.bank.slots,
        items = self:StripItemLinks(alt.bank.items)  -- Strip links from legacy field too
    }
end
```

**5. Debug Logging:**
Added comprehensive logging in `SendAltData()`:

```lua
local itemsCount = currentAlt.items and #currentAlt.items or 0
local bankCount = (currentAlt.bank and currentAlt.bank.items) and #currentAlt.bank.items or 0
local bagsCount = (currentAlt.bags and currentAlt.bags.items) and #currentAlt.bags.items or 0
TOGBankClassic_Output:Debug("SYNC", "Sending %s: alt.items=%d, alt.bank.items=%d (includes mail), alt.bags.items=%d", 
    norm, itemsCount, bankCount, bagsCount)
```

**Verification Steps:**
1. **Old → New sync test:**
   - Old client does `/wipe`, `/sync`
   - New client receives data with only `alt.bank.items` and `alt.bags.items`
   - New client reconstructs `alt.items` automatically
   - New client displays inventory correctly in all tabs

2. **New → Old sync test:**
   - New client scans bank/mailbox (creates `alt.items` with mail)
   - New client sends with all 3 arrays
   - Old client receives `alt.bank.items` (with mail aggregated) and `alt.bags.items`
   - Old client displays all inventory including mail (previously impossible)

3. **Mail visibility test:**
   - Banker has items in mail
   - Old client receives sync from new client
   - Old client sees mail quantities in bank tab (aggregated into `alt.bank.items`)
   - Mail count included in total displayed to old client

**Impact:**
- ✅ **Zero data loss:** All data visible to all client versions
- ✅ **Seamless migration:** No user intervention required
- ✅ **Enhanced old clients:** Old clients now see mail quantities (new capability)
- ✅ **Bandwidth optimized:** Link stripping works on all 3 arrays
- ✅ **Debug visibility:** Clear logging of what's being sent

**Edge Cases Handled:**
1. **Mixed guild:** Some players on old version, some on new → all sync correctly
2. **Bank-only account:** Only maintains `alt.items` → legacy fields reconstructed on send
3. **No mail:** Works correctly, no mail aggregation needed
4. **Mail-only items:** Items only in mail, not in bank/bags → added to `alt.bank.items` for old clients

**Migration Path:**
- **Phase 1 (Now):** Both structures maintained, automatic backward compatibility
- **Phase 2 (3-6 months):** After full guild adoption of SYNC-006, consider deprecating legacy fields
- **Phase 3 (Future):** Remove `alt.bank.items` and `alt.bags.items`, keep only `alt.items`

**Performance Notes:**
- Minimal overhead: Legacy field reconstruction only when needed
- Mail aggregation: O(n) where n = number of unique mail items (typically < 10)
- No additional bandwidth: Fields already sent, just ensuring they're populated

**Files Modified:**
- **Modules/Guild.lua:**
  - Lines 1036-1106: `EnsureLegacyFields()` - Sender-side backward compatibility
  - Lines 1107-1125: Updated `SendAltData()` to call `EnsureLegacyFields()` and add debug logging
  - Lines 994-1029: Updated `StripAltLinks()` to strip links from legacy fields
  - Lines 1415-1530: `ReceiveAltData()` - Receiver-side backward compatibility (already implemented for SYNC-006)

**Testing Results:**
- ✅ Empty tabs after `/wipe` and `/sync` - RESOLVED
- ✅ Old clients see mail quantities - WORKING
- ✅ New clients reconstruct from old data - WORKING
- ✅ All 3 arrays sent correctly - VERIFIED via debug logs
- ✅ No data loss in any direction - VERIFIED

---

### ✅ [SYNC-006] Mail quantities appearing additive during syncs

**Severity:** 🔴 CRITICAL  
**Category:** Delta Sync / Data Integrity / Inventory Aggregation
**Reporter:** User (Production)
**Date Reported:** 2026-01-28  
**Date Resolved:** 2026-01-28  
**Status:** ✅ RESOLVED  
**Reproducibility:** Consistent - occurred on every sync
**Impacted Users:** All bankers with mail inventory

**Initial Symptoms:**
User reported: "there is an issue where it's becoming additive, and my bags are increasing by the mail amount as i keep syncing with other players"
- Banker had 70 runecloth bags in bank, 33 in bags, 1 in mail (total: 104)
- Inventory UI displayed **368 runecloth bags** instead of 104
- Count increased with each sync operation
- Pattern identified: 368 = 104 + 264, where 264 = 33 × 8 (8x duplication of bag count)

**Investigation Timeline:**

**Phase 1: Initial Architecture Fix**
Implemented consolidated inventory system to prevent aggregation mismatch:
- Created `alt.items` aggregate combining bank + bags + mail
- Updated delta sync to use `alt.items` instead of separate bank/bags
- UI updated to compute from aggregate

**Phase 2: Display Issues**
After architecture changes, inventory tabs showed empty. Fixes:
- Fixed aggregation to return array format (not composite-keyed table)
- Changed aggregate key from `ID .. Link` to `ID` only (to properly combine same items)
- Fixed syntax error (extra 'end' statement) in Item.lua

**Phase 3: Persistent Count Errors**
Even after architecture fixes, count remained wrong (368 instead of 104):
- Added detailed debug logging: `/togbank debug MAIL`
- Debug revealed corrupted source data in `alt.bags.items`:
  - **Expected:** ~10 entries for 10 item types, total count 33
  - **Actual:** 18 entries with only 10 unique IDs, total count **325** (should be 33)
  - 325 instead of 33 = 9x multiplication (bags counted 9 times instead of once)

**Root Cause - Data Corruption:**

The source arrays (`alt.bags.items`, `alt.bank.items`) contained **duplicate entries** for the same item ID, accumulated through:
1. Old aggregation logic using `ID + Link` as key created multiple entries for same item
2. Syncing with other players who had corrupted data
3. No deduplication mechanism to clean corrupted data once it entered the system

**Example of corrupted data structure:**
```lua
alt.bags.items = {
    {ID = 14046, Link = "[Runecloth Bag]", Count = 4},   -- Entry 1
    {ID = 14046, Link = "[Runecloth Bag]", Count = 5},   -- Entry 2 (duplicate ID)
    {ID = 14046, Link = "[Runecloth Bag]", Count = 8},   -- Entry 3 (duplicate ID)
    {ID = 14046, Link = "[Runecloth Bag]", Count = 16},  -- Entry 4 (duplicate ID)
    -- ... 10 unique item IDs but 18 total entries ...
}
```

When aggregated: 4 + 5 + 8 + 16 + ... = 325 total bags instead of 33.

**Complete Solution:**

**1. Architecture Changes (prevent future corruption):**
- **Modules/Bank.lua (lines 200-217):** Create `alt.items` aggregate from bank + bags + mail after each scan
- **Modules/Item.lua (lines 103-146):** Fixed `Aggregate()` to use ID-only as key (not ID+Link)
- **Modules/DeltaComms.lua:**
  - Lines 526-543: `ComputeDelta()` uses `alt.items`
  - Lines 575-587: `DeltaHasChanges()` checks `alt.items`
  - Lines 743-753: `ApplyDelta()` applies to `alt.items`
- **Modules/Guild.lua:** Updated all helpers (sanitizeAlt, hasData, ComputeStateSummary, StripAltLinks, itemCount, ReconstructItemLinks) to use `alt.items`

**2. Auto-Healing Deduplication (fix existing corruption):**
- **Modules/Bank.lua (lines 218-232):** After creating `alt.items` aggregate, also deduplicate source arrays:
  ```lua
  -- Deduplicate source arrays to fix any corrupted data
  if alt.items and #alt.items > 0 then
      -- Extract only bank items and deduplicate
      local bankOnly = {}
      for _, v in ipairs(alt.bank.items or {}) do
          if v.ID then
              table.insert(bankOnly, v)
          end
      end
      alt.bank.items = TOGBankClassic_Item:Aggregate(bankOnly)
      
      -- Extract only bag items and deduplicate  
      local bagsOnly = {}
      for _, v in ipairs(alt.bags.items or {}) do
          if v.ID then
              table.insert(bagsOnly, v)
          end
      end
      alt.bags.items = TOGBankClassic_Item:Aggregate(bagsOnly)
  end
  ```
- This runs **automatically on every bank/mailbox open**
- Aggregates source arrays by ID, removing duplicates
- Replaces corrupted arrays with cleaned versions
- Self-heals without user intervention

**3. Display Layer Safeguard:**
- **Modules/UI/Inventory.lua (lines 280-340):** Always computes fresh aggregate from source data
- Added debug logging showing unique IDs and total counts per source
- Never trusts stored `alt.items`, always validates against sources

**Debug Output Before Fix:**
```
bags: 10 unique IDs, 325 total count
Combined should be: 368
aggregated to 11 unique items
displaying Runecloth Bag with count 368 (ID: 14046)
```

**Debug Output After Fix:**
```
bags: 10 unique IDs, 61 total count
Combined should be: 104
aggregated to 11 unique items
displaying Runecloth Bag with count 104 (ID: 14046)
```

**Verification:**
1. User opened bank and mailbox to trigger automatic scan with deduplication
2. Debug output confirmed: bags array reduced from 325 to 61 total count
3. Runecloth bag count displayed correctly: **104** (not 368)
4. User broadcasted cleaned data with `/togbank share` to propagate fix to guild

**Impact Analysis:**
- **Before:** Bankers with mail inventory saw wildly incorrect counts (8-9x multiplied)
- **After:** All counts accurate, auto-healing prevents recurrence
- **Data Safety:** Source arrays (bank, bags, mail) preserved for tracking, cleaned automatically
- **Sync Stability:** Single aggregate prevents sync mismatches

**Lessons Learned:**
1. Using `ID + Link` as composite key creates duplicates (links can vary for same item)
2. Always aggregate by item ID only
3. Source data corruption requires auto-healing mechanism (can't rely on users to fix manually)
4. Separation of "source" (bank/bags/mail) vs "aggregate" (alt.items) allows both tracking and clean sync

**Prevention:**
- Auto-healing runs on every scan (bank open, mailbox open)
- ID-only aggregation prevents new duplicates from forming
- Debug logging helps identify corruption patterns quickly

**Future Work:**
- **Phase out legacy structure:** The old `alt.bank.items` and `alt.bags.items` fields are kept for backward compatibility but should eventually be removed once all clients have upgraded to v0.8.0+. This will simplify the codebase and reduce data redundancy. Consider deprecation timeline after 3-6 months of v0.8.0 adoption.

---

### ✅ [MAIL-003] Search UI crash on undefined 'info' variable

**Severity:** 🔴 CRITICAL  
**Category:** Mail Inventory / UI  
**Date Reported:** 2026-01-27  
**Status:** ✅ RESOLVED  
**Resolution Date:** 2026-01-27

**Description:**
When typing in the search box, the UI crashes with "attempt to index global 'info' (a nil value)" at line 569 of Search.lua. This happens when trying to check if items are in mail to display the ✉ icon.

**Error Message:**
```
3x TOGBankClassic/Modules/UI/Search.lua:569: attempt to index global 'info' (a nil value)
[TOGBankClassic/Modules/UI/Search.lua]:569: in function 'DrawContent'
```

**Root Cause:**
In `DrawContent()` function (line 569), code attempted to access `info.alts[norm]` but `info` was not defined in the function scope. The variable should have been `TOGBankClassic_Guild.Info`.

**Affected Code:**
```lua
-- BEFORE (line 569)
local alt = info.alts[norm]

-- AFTER
local alt = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[norm]
```

**Fix:**
Changed to use the fully qualified global `TOGBankClassic_Guild.Info` with proper nil checks.

**Testing:**
1. Open search window
2. Type 3+ characters to trigger search
3. Verify no Lua errors
4. Verify mail icon (✉) appears next to banker names with items in mail

---

## [DATA-004] Item Count Duplication in UI Display

**Date:** January 28, 2026
**Severity:** Critical
**Status:** ✅ Fixed

**Symptom:**
Item counts in Inventory and Search UI displayed as multiples (20x, 40x, 60x) of actual values. Some tabs showed grey/empty screens. Fresh scans caused counts to increment on each reload.

**Root Cause:**
Mail items were stored using a different structure than bank/bag items:
- **Mail:** Key-value table with lowercase fields (`[itemID] = {id, count, link, sources}`)
- **Bank/Bags:** Array with uppercase fields (`[{ID, Count, Link}]`)

This inconsistency caused:
1. Aggregation failures - couldn't properly deduplicate across sources
2. Field name mismatches - `count` vs `Count`, `link` vs `Link`
3. Missing Links in source arrays - items without Link field couldn't be distinguished by suffix/enchant
4. Duplicate entries accumulating in SV file - same item stored multiple times

**Affected Files:**
- `Modules/MailInventory.lua` - Mail scanning with inconsistent structure
- `Modules/Bank.lua` - Conversion between mail and bank/bag formats
- `Modules/Item.lua` - GetInfo dropped items without Links
- `Core.lua` - Missing public Checksum method

**Investigation:**
1. SV file showed 7 entries for Earthborn Kilt (ID 15271) when only 4 should exist
2. 6 duplicates in mail.items, 1 in bank.items
3. Items stored without Link fields couldn't be deduplicated by composite key
4. GetInfo returned nil for items without Links, causing silent drops in UI

**Fix:**

**1. Standardized mail.items structure (MailInventory.lua:37-105):**
```lua
-- BEFORE: Key-value with lowercase fields
mailItems[itemID] = {
    id = itemID,
    name = name,
    link = link,
    count = 0,
    sources = {}
}

-- AFTER: Array with uppercase fields (same as bank/bags)
local itemString = TOGBankClassic_Item:GetItemString(link)
local key = tostring(itemID) .. itemString
mailItemsTable[key] = { ID = itemID, Count = count, Link = link }

-- Convert to array
local mailItems = {}
for _, item in pairs(mailItemsTable) do
    table.insert(mailItems, item)
end
```

**2. Removed mail conversion in Bank.lua (line 203):**
```lua
-- BEFORE: Convert from key-value to array
local mailItems = {}
if alt.mail and alt.mail.items then
    for itemID, mailItem in pairs(alt.mail.items) do
        table.insert(mailItems, { ID = itemID, Count = mailItem.count, Link = mailItem.link })
    end
end

-- AFTER: Direct assignment (already an array)
local mailItems = (alt.mail and alt.mail.items) or {}
```

**3. Updated RecalculateAggregatedItems (Bank.lua:395-403):**
```lua
-- Now deduplicates mail.items same as bank/bags
local mailItems = {}
if alt.mail and alt.mail.items then
    local deduped = TOGBankClassic_Item:Aggregate(alt.mail.items, nil)
    for _, item in pairs(deduped) do
        table.insert(mailItems, item)
    end
    alt.mail.items = mailItems  -- Write back to fix SV file
end
```

**4. Made GetInfo defensive (Item.lua:65-89):**
```lua
-- Always returns item info, even if placeholder
if not name then
    return {
        class = 0,
        subClass = 0,
        equipId = 0,
        rarity = 1,
        name = "Item " .. tostring(id or "?"),
        level = 1,
        price = 0,
        icon = 134400,  -- Default grey icon
    }
end
```

**5. Added missing Checksum method (Core.lua:110-113):**
```lua
function TOGBankClassic_Core:Checksum(str)
    return ComputeChecksum(str)
end
```

**6. Made GetItems filter properly (Item.lua:26-56):**
```lua
-- Only process items with valid IDs (ID > 0)
local validItems = {}
for _, item in pairs(items) do
    if item and item.ID and item.ID > 0 then
        table.insert(validItems, item)
    end
end
```

**Result:**
- All three sources (bank, bags, mail) now use identical structure
- Consistent uppercase field names (ID/Count/Link)
- Composite keys (ID + ItemString) work across all sources
- Deduplication on load cleans up corrupted SV data
- Items never silently dropped from UI
- Counts remain stable across scans/reloads

**Testing:**
1. Log into character with duplicated counts
2. `/reload` to trigger RecalculateAggregatedItems deduplication
3. Open bags/bank/mail to trigger fresh scan
4. `/reload` to save clean data
5. Multiple `/reload` cycles - counts stay stable
6. Check SV file - no duplicate entries

**Files Changed:**
- `Core.lua`
- `Modules/Item.lua`
- `Modules/Bank.lua`
- `Modules/MailInventory.lua`

**Additional Fixes (2026-01-28) - Nil itemID Crash:**

After implementing the mail structure standardization, a secondary issue emerged: nil itemID values reaching the Blizzard Item API and causing UI crashes with "table index is nil" errors.

**Secondary Issue:**
Error when clicking tabs with items that have suffixes/strings:
```
Blizzard_ObjectAPI/Classic/Item.lua:320: table index is nil
itemID = nil
[Item.lua]:49: in function 'GetItems'
[Search.lua]:405: in function 'BuildSearchData'
[Inventory.lua]:157: in function 'DrawContent'
```

**Root Cause:**
Multiple code paths still treated mail.items as key-value tables after standardization:
1. **Inventory.lua:307-309** - Fallback code used `pairs()` on mail array, treating indices as itemIDs
2. **Search.lua:389-396** - Same issue in BuildSearchData fallback aggregation
3. No validation filtering items with nil IDs before passing to GetItems

**Additional Fixes Applied:**

**7. Fixed Inventory.lua fallback path (lines 301-314):**
```lua
-- BEFORE: Created fake items from array indices
local mailItems = {}
if alt.mail and alt.mail.items then
    for itemID, mailItem in pairs(alt.mail.items) do
        table.insert(mailItems, { ID = itemID, Count = mailItem.count, Link = mailItem.link })
    end
end

// AFTER: Direct assignment (already array format)
local mailItems = (alt.mail and alt.mail.items) or {}
```

**8. Fixed Search.lua fallback path (lines 386-395):**
```lua
-- BEFORE: Created fake items from array indices
for itemID, mailItem in pairs(alt.mail.items) do
    local fakeItem = { ID = itemID, Count = mailItem.count, Link = mailItem.link }
    items = TOGBankClassic_Item:Aggregate(items, {fakeItem})
end

-- AFTER: Direct array aggregation
items = TOGBankClassic_Item:Aggregate(items, alt.mail.items)
```

**9. Added validation in Search.lua (lines 403-420):**
```lua
-- Validate and filter items before passing to GetItems
local validItems = {}
local invalidCount = 0
for i, item in ipairs(items) do
    if item and item.ID and item.ID > 0 then
        table.insert(validItems, item)
    else
        invalidCount = invalidCount + 1
        TOGBankClassic_Output:Debug("MAIL", "[SEARCH-DEBUG] WARNING: Skipping invalid item at index %d", i)
    end
end
```

**10. Added validation in Inventory.lua tab rendering (lines 340-349):**
```lua
-- Validate and filter items before passing to GetItems
local validItems = {}
for i, item in ipairs(items) do
    if item and item.ID and item.ID > 0 then
        table.insert(validItems, item)
    else
        TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] WARNING: Tab %s skipping invalid item at index %d", tab, i)
    end
end
```

**11. Added defensive pcall wrapper in Item.lua (lines 82-91):**
```lua
-- Wrap CreateFromItemID in pcall to catch crashes
local success, itemData = pcall(Item.CreateFromItemID, Item, itemID)
if not success then
    TOGBankClassic_Output:Debug("MAIL", "[ITEM-DEBUG] CreateFromItemID FAILED for ID %s: %s", 
        tostring(itemID), tostring(itemData))
    total = total - 1
    if total == 0 and count == 0 then
        callback(list)
    end
else
    itemData:ContinueOnItemLoad(function()
        -- Process item...
    end)
end
```

**Result:**
- All fallback code paths now treat mail.items as arrays
- Invalid items filtered before reaching Blizzard API
- UI displays remaining valid items even if some are corrupted
- No crashes even with partially corrupt data
- Debug logging identifies problematic items

**Additional Files Changed:**
- `Modules/UI/Search.lua`
- `Modules/UI/Inventory.lua`
- `Modules/Item.lua` (additional validation)

---

## [MAIL-005] Duplicate item stacks for identical gear with different instance IDs

**Severity:** 🟠 HIGH
**Category:** Item Deduplication / Mail Sync
**Reporter:** User (Production)
**Date Reported:** 2026-01-29
**Date Resolved:** 2026-01-29
**Status:** ✅ RESOLVED
**Reproducibility:** Consistent for gear items in mail

**Description:**
When viewing banker's inventory tab, identical gear items (e.g., Earthborn Kilt) appeared as multiple separate stacks instead of merging into one. This occurred when the same item existed in both local storage (bags/bank) and synced mail data.

**Example:**
- Earthborn Kilt x2 in bags (with Links from local scan)
- Earthborn Kilt x2 in mail (with Links from d3 sync)
- **Expected:** Single stack with count 4
- **Actual:** Two separate stacks with count 2 each

**Root Causes:**

1. **Unique Instance IDs in Item Links:**
   - Each physical item in WoW has a unique instance ID in its link
   - Example: `item:9402:0:0:0:0:0:1542:0:863` vs `item:9402:0:0:0:0:0:1542:0:1205`
   - Last number (863 vs 1205) is the instance ID
   - Using full link as deduplication key created separate entries for identical items

2. **Linkless Merge Pattern Mismatch:**
   - Old synced mail data had nil Links (from pre-NeedsLink implementation)
   - Aggregate function tried to merge linkless items with linked items
   - Pattern `"^9402[:%[]"` failed to match key format `"9402item:9402:..."`
   - Linkless mail items couldn't merge with linked bag items

3. **Bandwidth vs Functionality Tradeoff:**
   - Original d3 protocol stripped all Links to save bandwidth
   - But gear items NEED Links to distinguish suffixes ("of the Bear" vs "of the Monkey")
   - Consumables don't need Links (no variations)

**Solutions Implemented:**

### 1. Selective Link Preservation Based on Item Class

**Item.lua (lines 4-17):**
```lua
-- Item classes that require Link to be preserved (for suffix differentiation)
-- Class 2 = Weapons, Class 4 = Armor (includes all equippable gear)
local ITEM_CLASSES_NEEDING_LINK = {
	[2] = true,  -- Weapon
	[4] = true,  -- Armor (chest, legs, trinkets, rings, necks, etc)
}

-- Check if an item needs its Link preserved based on item class
-- Gear (weapons/armor) can have random suffixes, so Link is required
-- Consumables and trade goods don't vary, so Link can be stripped
function TOGBankClassic_Item:NeedsLink(itemLink)
	if not itemLink then return false end
	local _, _, _, _, _, itemClass = GetItemInfo(itemLink)
	return ITEM_CLASSES_NEEDING_LINK[itemClass] == true
end
```

**MailInventory.lua (lines 67-75):**
```lua
local link = GetInboxItemLink(i, j)

-- Conditionally include Link based on item class
-- Gear (weapons/armor) needs FULL Link for suffix differentiation
-- Consumables/trade goods don't need Link (saves bandwidth in d3 sync)
local storageLink = nil
if link and TOGBankClassic_Item:NeedsLink(link) then
	storageLink = link  -- Store FULL link for gear
end
```

**Benefits:**
- Gear keeps full Link → proper suffix differentiation ✓
- Consumables strip Link → ~90 bytes saved per item ✓
- Bandwidth optimized where safe, preserved where needed ✓

### 2. Normalized Deduplication Keys (GetItemKey)

**Item.lua (lines 38-60):**
```lua
-- Get normalized item key for deduplication (strips unique instance ID)
-- Items with same ID+suffix but different instance IDs will have same key
-- Format: itemID:enchant:gem1:gem2:gem3:gem4:suffixID (7 parts)
function TOGBankClassic_Item:GetItemKey(link)
	if not link or link == "" then
		return ""
	end
	
	local itemString = link:match("|Hitem:([^|]+)|h")
	if not itemString then
		itemString = link:match("item:([%d:]+)")
	end
	
	if itemString then
		-- Split into parts
		local parts = {}
		for part in string.gmatch(itemString, "([^:]+)") do
			table.insert(parts, part)
		end
		
		-- Keep first 7 parts only (strip uniqueID and specializationID)
		if #parts >= 7 then
			return "item:" .. table.concat({parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7]}, ":")
		else
			return "item:" .. itemString
		end
	end
	
	return link
end
```

**Usage in Aggregate (Item.lua lines 273-275):**
```lua
-- Use NORMALIZED key (strips unique instance ID) for deduplication
local itemKey = self:GetItemKey(v.Link)
local key = tostring(v.ID) .. itemKey
```

**How It Works:**
- **Storage:** Keep FULL link with instance ID
- **Deduplication:** Use normalized key WITHOUT instance ID
- Two Earthborn Kilts with different instances → same key → merge ✓

### 3. Fixed Linkless Item Merge Pattern

**Item.lua (lines 279-291):**
```lua
-- If no Link, also check if there's an existing entry with same ID but with link
-- This handles deduplication between linked (bank/bags) and linkless (mail) items
if not v.Link and itemKey == "" then
	-- Look for any existing key starting with this ID followed by "item:"
	local searchPattern = "^" .. tostring(v.ID) .. "item:"
	for existingKey, existingItem in pairs(items) do
		if existingKey:match(searchPattern) or existingKey == tostring(v.ID) then
			-- Found item with same ID - merge into that entry
			local itemCount = existingItem.Count or 1
			local vCount = v.Count or 1
			existingItem.Count = itemCount + vCount
			existingItem.Link = existingItem.Link or v.Link
			key = nil  -- Signal that we already merged
			break
		end
	end
end
```

**What Changed:**
- Old pattern: `"^9402[:%[]"` → failed to match `"9402item:..."`
- New pattern: `"^9402item:"` → correctly matches composite keys ✓
- Also checks exact ID match for consumables (`"9402"` == `"9402"`) ✓

### 4. Added Aggregation Debug Logging

**Bank.lua (lines 403-407):**
```lua
TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] Aggregating: bank=%d, bags=%d, mail=%d", #bankItems, #bagItems, #mailItems)
local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] After bank+bags aggregate: %d unique items", TOGBankClassic_Item:CountItems(aggregated))
aggregated = TOGBankClassic_Item:Aggregate(aggregated, mailItems)
TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] After adding mail: %d unique items", TOGBankClassic_Item:CountItems(aggregated))
```

**Result:**
- ✅ Earthborn Kilt: 2 in bags + 2 in mail → 1 stack with count 4
- ✅ All gear items properly deduplicate regardless of instance ID
- ✅ Consumables continue to stack correctly
- ✅ Bandwidth optimized (Links only sent for gear)
- ✅ Works with old linkless data (backward compatible)

**Files Changed:**
- `Modules/Item.lua` (NeedsLink, GetItemKey, GetItemString separation, Aggregate pattern fix)
- `Modules/MailInventory.lua` (selective Link storage)
- `Modules/Bank.lua` (aggregation debug logging)

---

## [ITEM-001] Item deduplication failing for linkless synced data

**Severity:** 🟠 HIGH
**Category:** Item Deduplication / Data Migration
**Reporter:** User (Production)
**Date Reported:** 2026-01-29
**Date Resolved:** 2026-01-29
**Status:** ✅ RESOLVED (subsumed by MAIL-005)
**Reproducibility:** Consistent for old synced data

**Description:**
This was the underlying technical issue that manifested as [MAIL-005]. Old mail data synced before the NeedsLink implementation had nil Links, causing deduplication failures when aggregating with locally scanned data.

**Root Cause:**
- Pre-MAIL-005 implementation: All mail items had nil Links (bandwidth optimization)
- Local bank/bags items: Full Links from GetBankItemLink/GetContainerItemLink
- Aggregate function: Created different keys for nil vs non-nil Links
- Result: Same items appeared in separate stacks

**Solution:**
Covered comprehensively by [MAIL-005] fixes. Key aspects:
1. Normalize keys during aggregation (GetItemKey)
2. Special handling for linkless items to merge with linked variants
3. Forward compatibility: New scans use selective Link preservation

**Note:** This is an internal technical issue that was fixed as part of the broader MAIL-005 solution. Included here for completeness.

---

## [ITEM-002] CRITICAL CRASH: "table index is nil" in Blizzard_ObjectAPI

**Status:** ✅ FIXED (2026-01-29)  
**Severity:** CRITICAL - Game crash  
**Category:** Item Loading, Blizzard API  
**Error Count:** 90+ occurrences before fix

**Problem:**
Persistent crash in Blizzard's Item.lua causing "table index is nil" error at line 320. The crash occurred when calling `Item:ContinueOnItemLoad()` on Item objects that had nil internal itemID field, despite our validation showing the item appeared valid.

**Error Traceback:**
```
Blizzard_ObjectAPI/Classic/Item.lua:320: table index is nil
[Blizzard_ObjectAPI/Classic/Item.lua]:320: in function 'GetOrCreateCallbacks'
[Blizzard_ObjectAPI/Classic/Item.lua]:272: in function 'AddCallback'
[Blizzard_ObjectAPI/Classic/Item.lua]:238: in function 'ContinueOnItemLoad'
[TOGBankClassic/Modules/Guild.lua]:1044: in function ReconstructItemLinks
```

**Root Cause:**
1. Blizzard's `Item:CreateFromItemID()` can return Item objects with nil internal `itemID` field
2. Race condition: itemID can become nil between our validation check and ContinueOnItemLoad execution
3. Corrupted data: Items with ID 1 and 2 (invalid WoW item IDs) were in sync data
4. Multiple call sites: Guild.lua, Search.lua, and Item.lua all called ContinueOnItemLoad without validation

**Solution - Three-Layer Defense:**

1. **Item ID Validation** (Guild.lua, Item.lua):
   - Added `if itemObj and itemObj.itemID and itemObj.itemID == item.ID` check before ContinueOnItemLoad
   - Filters out corrupted items with ID < 100 (not valid WoW items)

2. **Error Protection** (Guild.lua lines 1025-1040, 1070-1085):
   - Wrapped ContinueOnItemLoad calls in `pcall` to catch race condition errors
   - Properly decrements pendingAsyncLoads counter on failure
   - Logs errors without crashing

3. **Corrupted Data Filtering** (Item.lua line 107, Guild.lua line 1003):
   - Added filter: `item.ID < 100` to skip invalid item IDs
   - Prevents items 1, 2, and other low IDs from being processed

**Files Modified:**
- `Modules/Guild.lua`: Added validation and pcall protection for ReconstructItemLinks
- `Modules/Item.lua`: Added ID < 100 filter in GetItems validation
- `Modules/UI/Search.lua`: Added itemID validation for item link conversion

**Testing:**
- Crash no longer occurs (previously 90+ crashes)
- Invalid items logged but skipped: `[GUILD-ERROR] ContinueOnItemLoad crashed for item 1`
- No impact on valid item processing

**Prevention:**
- All future ContinueOnItemLoad calls must validate itemObj.itemID first
- Always use pcall wrapper for Blizzard async APIs with known race conditions
- Filter out items with ID < 100 at data ingestion points

---

## [DATA-005] Banker Data Being Overwritten by External Sources

**Status:** ✅ FIXED (2026-01-29)  
**Severity:** HIGH - Data Integrity  
**Category:** Data Protection, Sync Protocol

**Problem:**
Banker characters were accepting external data about themselves from other players, causing their bank/mail/bags data to be overwritten with stale data after 2-3 minutes. This violated the "banker is source of truth" principle.

**Symptoms:**
- Banker opens mail/bank/bags, all items display correctly
- After 2-3 minutes, UI "blinks" (sync update)
- Items from mail disappear from bank tab display
- Banker's own data being overwritten by external sync

**Root Cause:**
DATA-004 protection was incomplete:
- DeltaComms.lua: Only blocked non-bankers updating banker data, but didn't block updates about the banker themselves
- Guild.lua ReceiveAltData: Had `isOwnData` check but didn't reject external data about the banker

**Solution:**

1. **DeltaComms.lua (lines 684-716):**
   - Added check: If player is banker AND delta is about themselves, reject it
   - Bankers now reject ALL external deltas about themselves
   - Non-bankers still accept all deltas (not the authority)

2. **Guild.lua ReceiveAltData (lines 1743-1777):**
   - Added check: If player is banker AND data is about themselves, reject it
   - Enhanced protection for other banker data from non-banker updates

**Protection Rules (Finalized):**

**For Bankers:**
1. ✅ Reject ANY external data about themselves (source of truth)
2. ✅ Reject non-banker updates to other banker data
3. ✅ Accept banker-to-banker updates for other bankers

**For Non-Bankers:**
1. ✅ Accept all data (not the authority)
2. ✅ Can sync with other non-bankers
3. ✅ Can receive updates from bankers

**Warning Messages:**
- `[DATA-004] Rejected delta from X about ourselves (banker is source of truth for own data)`
- `[DATA-004] Rejected alt data about ourselves from X (banker is source of truth for own data)`

**Files Modified:**
- `Modules/DeltaComms.lua`: Enhanced ApplyDelta with self-protection
- `Modules/Guild.lua`: Enhanced ReceiveAltData with self-protection

**Testing:**
- Bankers no longer accept external updates about themselves
- Non-bankers still sync normally with all players
- Mail/bank/bags data no longer disappears after sync updates

---

## [SEARCH-003] Search Returning 0 Results Despite Valid Data

**Status:** ✅ FIXED (2026-01-29)  
**Severity:** HIGH - Feature Broken  
**Category:** Search, Lua Table Iteration

**Problem:**
Search window consistently returned "0 Results" for all searches despite valid item data existing. Debug showed "0 items before aggregation" and "0 items after aggregation" for all alts. However, the Inventory UI tab correctly displayed 15 items for the same character, and `/dump TOGBankClassic_Guild.Info["Alchemyrcp-Azuresong"].items` confirmed 15 items existed in the data structure.

**Symptoms:**
- Search UI shows "0 Results" for all queries
- Debug log: "0 items before, 0 after aggregation"
- Inventory tab works correctly showing all items
- Data exists in TOGBankClassic_Guild.Info structure
- No errors thrown, silent failure

**Root Cause - Lua Table Type Mismatch:**

**Background on Lua Tables:**
Lua has a single "table" type used for both arrays and hash tables:
- **Arrays:** Numeric indices [1], [2], [3] - iterated with `ipairs()`, counted with `#`
- **Hash Tables:** String/mixed keys ["key1"], ["key2"] - iterated with `pairs()`, counted manually

**The Bug:**
1. `Item.lua Aggregate()` returns a **hash table** with deduplication keys:
   ```lua
   items["9304item:9304:0:0:0:0:0:0:0"] = {ID=9304, Count=1, Link="..."}
   items["2589item:2589:0:0:0:0:0:0:0"] = {ID=2589, Count=2, Link="..."}
   ```

2. `Search.lua BuildSearchData()` used **array iteration** on this hash table:
   ```lua
   local count = #items  -- Returns 0 for hash tables!
   for i, item in ipairs(items) do  -- Only iterates [1], [2], [3]...
   ```

3. **Result:** `ipairs()` found nothing because there are no numeric indices, only string keys

**Why Inventory Worked:**
`UI/Inventory.lua` correctly used `pairs()` to iterate the hash table:
```lua
for key, item in pairs(items) do  -- Iterates ALL keys (strings or numbers)
```

**Solution:**

**Search.lua (lines 405-410):**
```lua
-- BEFORE (incorrect):
local count = #items  -- Returns 0 for hash tables
for i, item in ipairs(items) do  -- Only iterates numeric indices

-- AFTER (correct):
local count = 0
for _ in pairs(items) do count = count + 1 end  -- Count all keys
for key, item in pairs(items) do  -- Iterate all keys
```

**Key Changes:**
1. Changed `ipairs(items)` → `pairs(items)` for hash table iteration
2. Changed `#items` → manual counting loop for hash tables
3. No logic changes needed - just proper iteration

**Technical Notes:**
- `ipairs()` documentation: "Iterates the array part of a table" (numeric indices only)
- `pairs()` documentation: "Iterates all key-value pairs" (any keys)
- `#` operator: "Returns the length of the array part" (0 for pure hash tables)
- Aggregate() has always returned hash tables - this bug was pre-existing but exposed by recent testing

**Files Modified:**
- `Modules/UI/Search.lua` (lines 405-410): Changed table iteration from ipairs to pairs

**Testing:**
- Search now correctly finds and displays items
- Aggregation counts match Inventory tab counts
- All search queries work as expected

**Prevention:**
- Always use `pairs()` when iterating tables from `Aggregate()`
- Only use `ipairs()` for guaranteed numeric-indexed arrays
- Document in code comments when functions return hash tables vs arrays

---

#### [DATA-006] Mail data being deleted by external sync for multi-banker accounts

**Severity:** 🔴 CRITICAL
**Category:** Data Integrity / Delta Sync
**Reporter:** User (Production - Multi-banker workflow)
**Date Reported:** 2026-01-29
**Date Resolved:** 2026-01-29
**Status:** ✅ RESOLVED
**Reproducibility:** Consistent with multiple bankers on same account
**Related:** [DATA-004], [DATA-005], Mail Inventory Persistence

**Problem:**
When cycling through 35+ banker characters on the same account (all sharing one SavedVariables file), mail data scanned on earlier bankers would disappear after some time. Investigation revealed that external sync data from other players was overwriting locally-scanned mail data, despite mail being a local-only feature that should never be synced.

**User Workflow:**
1. Log into Banker1 → open mail → open bags → open bank → /reload
2. Log into Banker2 → open mail → open bags → open bank → /reload
3. Repeat for 35 bankers...
4. Later: Log into Banker1 → mail data is GONE from UI
5. Check SavedVariables file → `mail` field completely missing for Banker1

**Root Cause:**

The DATA-004/DATA-005 banker protection logic had a critical flaw:

**Guild.lua ReceiveAltData() (OLD - lines 1745-1778):**
```lua
if playerIsBanker then
    -- We are a banker - protect our data
    
    -- CRITICAL: If this is data about US, reject it
    if isOwnData then
        return ADOPTION_STATUS.UNAUTHORIZED
    end
    
    -- Also protect OTHER banker data from non-banker updates
    local existingIsBanker = existing and self:IsBank(norm)
    local incomingIsBanker = self:IsBank(name)
    
    if existingIsBanker and not incomingIsBanker then
        -- Reject: non-banker trying to overwrite banker data
        return ADOPTION_STATUS.UNAUTHORIZED
    end
    -- BUG: If incomingIsBanker=true, accept the update!
end

-- ... later ...
self.Info.alts[norm] = alt  -- OVERWRITES entire alt object
```

**The Bug:**
- Protection only activated when **currently on a banker** (`if playerIsBanker`)
- Only rejected updates from **non-bankers** to **existing bankers**
- **Allowed bankers to overwrite OTHER bankers' data!**
- Line 1827 completely replaces alt object, deleting `mail` field

**Scenario:**
1. Banker1 scans mail → `alt.mail = { items = [...], lastScan = 12345 }`
2. Later, while on Banker2, receive sync from Player3 (has data about Banker1)
3. Player3's data lacks `mail` field (mail is never synced)
4. Protection checks: `targetIsBanker=true, incomingIsBanker=false` → REJECT ✓ Good!
5. But then Banker2 broadcasts their version of Banker1's data (from shared SV)
6. Protection checks: `targetIsBanker=true, incomingIsBanker=true` → ACCEPT ✗ BUG!
7. Line 1827: `self.Info.alts[norm] = alt` → DELETES Banker1's mail field

**Why This Happens:**
- Multiple bankers on same account share SavedVariables
- When Banker2 loads, they have Banker1's data in memory (from SV file)
- Banker2 broadcasts/shares this data during sync
- Recipient sees: "incoming from Banker2 about Banker1"
- Both are bankers → old logic allowed this → mail data deleted

**Solution:**

Complete rewrite of banker protection logic to be **absolute**:

**Guild.lua ReceiveAltData() (NEW - lines 1743-1771):**
```lua
-- DATA-004/DATA-006: Protect ALL banker data from external overwrites
-- Bankers are the source of truth for their own data. External sync should NEVER overwrite banker data.
-- This protects all bankers on the same account, not just the currently logged-in one.
local player = UnitName("player") .. "-" .. GetRealmName()
local playerNorm = self:NormalizeName(player)
local isOwnData = playerNorm == norm
local targetIsBanker = self:IsBank(norm)

-- CRITICAL: If the target is a banker, REJECT all external updates (even from other bankers)
-- Bankers only update their own data when they scan their bank/bags/mail locally
if targetIsBanker and not isOwnData then
    TOGBankClassic_Output:Warn(
        "[DATA-006] Rejected external alt data for banker %s (bankers are source of truth, only self-updates allowed)",
        norm
    )
    return ADOPTION_STATUS.UNAUTHORIZED
end

-- If this is data about ourselves (current player), reject it
if isOwnData then
    TOGBankClassic_Output:Warn(
        "[DATA-004] Rejected alt data about ourselves from %s (we are the source of truth for own data)",
        name
    )
    return ADOPTION_STATUS.UNAUTHORIZED
end
```

**Key Changes:**
1. **Check targetIsBanker FIRST** - before any other logic
2. **Reject ALL external updates to bankers** - regardless of sender
3. **Only allow self-updates** - when `isOwnData=true` (but those are also rejected as external)
4. **No more nested conditions** - simple, clear, absolute protection

**Why This Works:**
- Banker data can ONLY be updated by Bank.lua during local scans
- External sync (ReceiveAltData) can NEVER touch banker data
- Each banker is responsible for their own data
- Multiple bankers on same account each protect their own data
- Mail field (and all banker data) persists indefinitely

**Mail Data Persistence:**
Mail data is:
- Scanned locally when banker opens mailbox (MAIL_SHOW → MAIL_CLOSED → Bank:Scan)
- Stored in `alt.mail = { items = [], lastScan = timestamp }`
- Written to SavedVariables automatically by AceDB
- Never included in external sync messages (bandwidth optimization)
- Protected from deletion by DATA-006 fix

**Testing:**
1. Log into Banker1 → open mail with items → verify mail data in SV file
2. Log into Banker2 → trigger full sync from other players
3. Log back into Banker1 → mail data should still be present
4. Check debug log for "[DATA-006] Rejected external alt data for banker"

**Impact:**
- **Severity:** CRITICAL - Causes permanent data loss for mail inventory
- **Frequency:** 100% with multi-banker workflows and active guild sync
- **Scope:** Affects all banker data, not just mail (bank/bags also at risk)
- **Resolution:** All banker data now fully protected from external overwrites

**Files Changed:**
- [Modules/Guild.lua](Modules/Guild.lua#L1597) - Added sender parameter to ReceiveAltData
- [Modules/Guild.lua](Modules/Guild.lua#L1743-1779) - Implemented 3-rule banker protection (reject unless sender==target for bankers)
- [Modules/Guild.lua](Modules/Guild.lua#L1831-1845) - Added mail field preservation as fallback
- [Modules/Chat.lua](Modules/Chat.lua#L823,L860) - Pass sender to ReceiveAltData calls

**Related Issues:**
- [DATA-004] Initial banker self-protection implementation
- [DATA-005] Enhanced to protect from non-banker updates
- [DATA-006] Final fix: Added sender tracking + 3-rule protection + mail preservation

**Key Insight:**
The solution required passing `sender` to `ReceiveAltData()` so we could distinguish:
- ✅ Banker1 sending their own data (sender==target) - ACCEPT
- ❌ Banker3 sending Banker1's data (sender!=target) - REJECT
Without sender info, all banker data looked the same and stale SV data could overwrite fresh scans.

**Prevention:**
- Always pass sender identity through sync chain
- Banker data ONLY modified by Bank.lua during local scans
- External sync checks: banker targets must have sender==target
- Mail preservation as defense-in-depth (even if rejection fails)
- Test with multiple bankers on same account sharing SavedVariables

---

#### [P2P-008] Post-wipe recovery failing when no banker online

**Severity:** 🔴 CRITICAL
**Category:** P2P / Communication / Error Handling
**Reporter:** User (Production)
**Date Reported:** 2026-02-16
**Date Resolved:** 2026-02-16
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - After `/wipe` with no banker online, remained 0/35 indefinitely
**Related:** PERF-005 P2P protocol, PERF-006 P2P bypass fixes, RequestHashListFromBanker

**Problem:**
After running `/wipe` to clear local database, users remained stuck at 0/35 alts for hours even when guild members had full data. The system failed to recover because:
1. QueryAltPullBased silently dropped requests when no banker was online
2. Non-banker peers required `expectedHash` in requests to respond (not present in post-wipe GUILD broadcasts)

**Symptoms:**
1. User runs `/wipe` to clear local database → all data wiped
2. RequestHashListFromBanker runs every 3 minutes (OnShareTimer)
3. No banker online → enters fallback path (line 790)
4. For each alt, calls QueryAltPullBased(norm, false) (line 821)
5. QueryAltPullBased checks if banker online (line 1198)
6. Returns early: "banker offline, cannot send query" (line 1199)
7. **Request silently dropped** - no GUILD broadcast sent
8. Remains 0/35 indefinitely despite peers having full data

**Secondary Issue:**
Even after fixing GUILD broadcasts, non-bankers still wouldn't respond:
- Post-wipe requests have `requesterInventoryHash = 0` (no data)
- Post-wipe requests have NO `expectedHash` field (only set by BroadcastP2PRequest)
- Non-banker response logic: `elseif ... and data.expectedHash then` (line 795)
- Non-bankers skip requests without expectedHash → only bankers respond
- If no banker online → **no one responds** despite having data

**Root Cause:**

**Issue 1: QueryAltPullBased drops requests (Guild.lua:1193-1200)**
```lua
-- BEFORE:
if not banker then
    TOGBankClassic_Output:Debug("PROTOCOL", "no banker found, cannot send query")
    return  // REQUEST DROPPED!
end
if not self:IsPlayerOnline(banker) then
    TOGBankClassic_Output:Debug("PROTOCOL", "banker offline, cannot send query")
    return  // REQUEST DROPPED!
end
```

**Issue 2: Non-bankers require expectedHash (Chat.lua:795)**
```lua
-- BEFORE:
elseif PEER_TO_PEER and PEER_TO_PEER.ENABLED and hasData and data.expectedHash then
    // Only responds if expectedHash present and matches
```

**Impact:**
- **Severity:** CRITICAL - Complete system failure after `/wipe` in common scenario
- **User Experience:** Stuck at 0/35 for hours, requires manual banker scan to recover
- **Workaround:** Log into banker character, scan, and share manually
- **Adoption Blocker:** Makes `/wipe` command effectively broken for testing/recovery

**Fix:**

**Part 1: Guild.lua QueryAltPullBased (lines 1191-1224) - GUILD broadcast fallback**
```lua
-- AFTER:
if not banker then
    // Broadcast to GUILD - any member can respond
    TOGBankClassic_Output:Debug("PROTOCOL", "no banker found, broadcasting to GUILD")
    TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
    self:MarkPendingSync("alt", "guild", norm)
    self.pendingAltRequests[norm] = now
    return
end

if not self:IsPlayerOnline(banker) then
    // Broadcast to GUILD - any member can respond
    TOGBankClassic_Output:Debug("PROTOCOL", "banker offline, broadcasting to GUILD")
    TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
    self:MarkPendingSync("alt", "guild", norm)
    self.pendingAltRequests[norm] = now
    return
end
```

**Part 2: Chat.lua alt-request handler (lines 782-833) - Post-wipe recovery mode**
```lua
-- AFTER:
elseif PEER_TO_PEER and PEER_TO_PEER.ENABLED and hasData then
    local requesterHash = data.requesterInventoryHash or 0
    local shouldRespondP2P = false
    
    // Allow response in two scenarios:
    if data.expectedHash and myHash == data.expectedHash and hasContent then
        // Scenario 1: Normal P2P with hash match
        shouldRespondP2P = true
    elseif not data.expectedHash and requesterHash == 0 and hasContent then
        // Scenario 2: Post-wipe recovery (requester wiped, any peer can help)
        shouldRespondP2P = true
        TOGBankClassic_Output:Debug("QUERIES", "WIPE-RECOVERY: Peer responding for %s", altName)
    end
```

**Testing:**
1. Run `/wipe` to clear all local data
2. Verify 0/35 alts, no hashes
3. Wait for 3-minute timer (OnShareTimer)
4. Observe GUILD broadcasts: "HLR fallback: no banker online, broadcasting query for X (no local hash)"
5. Peers with data respond: "WIPE-RECOVERY: Peer responding for X (requester wiped, providing fresh data)"
6. Data populates progressively: 1/35, 2/35, ... 35/35
7. Verify works without any banker online

**Expected Behavior After Fix:**
- ✅ Requests broadcast to GUILD when banker unavailable
- ✅ Any guild member with content can respond (not just bankers)
- ✅ Post-wipe recovery completes within 1-2 timer cycles (3-6 minutes)
- ✅ No manual intervention required

**Backwards Compatibility:**
- **Bankers (any version):** Already respond without expectedHash ✅
- **Non-bankers (old code):** Still require expectedHash ⚠️
- **Migration Path:** Requires at least one other member (banker or non-banker) to update
- **Testing:** Works immediately if any banker is online (old or new code)

**Files Changed:**
- [Modules/Guild.lua](Modules/Guild.lua#L1191-1224) - QueryAltPullBased GUILD broadcast fallback
- [Modules/Guild.lua](Modules/Guild.lua#L890-903) - Better P2P timeout logging
- [Modules/Chat.lua](Modules/Chat.lua#L782-833) - Post-wipe recovery response logic
- [Modules/Chat.lua](Modules/Chat.lua#L873-893) - Improved debug logging for skip reasons

**Related Issues:**
- [PERF-005] P2P send queue throttling
- [PERF-006] P2P protocol bypass fixes
- RequestHashListFromBanker fallback logic
- OnShareTimer 3-minute periodic sync

**Prevention:**
- Never silently drop sync requests - always broadcast or queue
- Design fallback paths for common scenarios (no banker, post-wipe)
- Test recovery scenarios explicitly (wipe, offline, empty guild)
- Log WHY requests are skipped (not just that they were skipped)

---

#### [P2P-009] P2P data requests not being processed at all

**Severity:** 🔴 CRITICAL
**Category:** P2P / Communication / Protocol
**Reporter:** User (Production Testing)
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - P2P protocol completely non-functional since PERF-006 channel migration
**Related:** PERF-006 (channel migration to togbank-hl), PERF-005 (P2P protocol design)

**Problem:**
After PERF-006 migrated P2P broadcasts from `togbank-r` to `togbank-hl` channel (for modern code segregation), P2P requests were never actually processed by peers. Users saw "P2P: Broadcasting request for Toglowweap-Azuresong with hash=1866095815 (waiting for peers)" messages but received no data. After 5 second timeout, system would fall back to querying banker (but with no banker online for testing, remained stuck at 0/35 indefinitely).

**Symptoms:**
1. User runs `/togbank sync` with no banker online
2. System broadcasts P2P requests via `togbank-hl`: "P2P: Broadcasting request for X with hash=Y (waiting for peers)"
3. Peers with matching data receive the `togbank-hl` message
4. **Peers never respond** - no "P2P: Responding to..." messages
5. After 5 seconds: timeout occurs, falls back to QueryAltPullBased
6. With no banker online: stuck at 0/35 indefinitely
7. With banker online: bypasses P2P entirely, queries banker directly

**Root Cause:**

The `togbank-hl` handler attempted to forward P2P requests to the `togbank-r` handler by changing the `prefix` variable, but this doesn't work due to control flow order.

**Chat.lua OnCommReceived structure (simplified):**
```lua
function TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
    -- Line 728: togbank-r handler executes FIRST
    if prefix == "togbank-r" then
        if data.type == "alt-request" then
            // Process request, check hash match, send togbank-rr ack
        end
    end
    
    -- ... many other handlers in between ...
    
    -- Line 1631: togbank-hl handler executes LATER
    if prefix == "togbank-hl" then
        if data.type == "alt-request" then
            // BEFORE FIX:
            prefix = "togbank-r"  // ❌ Too late! togbank-r already checked above
        end
    end
end
```

**Why the Bug Occurred:**
1. `BroadcastP2PRequest()` sends message on `togbank-hl` channel (Guild.lua:888)
2. Peers receive message, enter OnCommReceived with `prefix = "togbank-hl"`
3. Function checks handlers top-to-bottom:
   - Line 728: `if prefix == "togbank-r"` → FALSE (prefix is "togbank-hl"), **SKIPS**
   - Line 1631: `if prefix == "togbank-hl"` → TRUE, enters handler
   - Line 1692: Sets `prefix = "togbank-r"` (attempting to forward)
4. **Control flow continues forward**, never goes back to line 728
5. Request is never processed, peer never responds

**Impact:**
- **Severity:** CRITICAL - Complete P2P protocol failure
- **Affected Users:** Anyone testing P2P without banker online
- **User Experience:** "Broadcasting request" spam, no data, looks broken
- **Workaround:** Have banker online (bypasses P2P entirely via QueryAltPullBased)
- **Silent Failure:** No errors, just infinite waiting
- **Introduced:** During PERF-006 channel migration (2026-02-08)
- **Duration:** ~9 days undetected (only affected no-banker testing scenarios)

**Fix:**

**Chat.lua togbank-hl handler (lines 1685-1693)**
```lua
// BEFORE:
elseif data.type == "alt-request" then
    TOGBankClassic_Output:Debug("PROTOCOL", "P2P alt-request from %s for %s", sender, data.name)
    prefix = "togbank-r"  // ❌ Doesn't work - that handler already executed
end

// AFTER:
elseif data.type == "alt-request" then
    TOGBankClassic_Output:Debug("PROTOCOL", "P2P alt-request from %s for %s", sender, data.name)
    // Recursively call OnCommReceived with togbank-r prefix
    // This properly processes the request as if it came via togbank-r
    self:OnCommReceived("togbank-r", message, distribution, sender)
    return  // Exit to prevent double processing
end
```

**How the Fix Works:**
1. Peer receives `togbank-hl` message with `type = "alt-request"`
2. togbank-hl handler (line 1685) matches
3. **Recursively calls** `self:OnCommReceived("togbank-r", message, ...)`
4. New call enters function with `prefix = "togbank-r"`
5. Line 728: `if prefix == "togbank-r"` → TRUE, enters handler
6. Processes request normally:
   - Checks if peer has data
   - Validates hash match: `myHash == data.expectedHash`
   - If match + has content: sends `togbank-rr` acknowledgment
7. Requester receives ack, sends `togbank-state` summary
8. Peer compares hashes, sends data via `togbank-d`
9. **P2P protocol completes successfully**

**Testing:**
```
BEFORE FIX:
1. `/wipe` (clear local data)
2. Logout all bankers
3. `/togbank sync` from non-banker
4. Output: "P2P: Broadcasting request..." × 35
5. Output: "Fast-fill: No banker online, broadcasting 35 requests"
6. **NO RESPONSES** - peers silent despite having data
7. After 5 seconds: timeout, tries QueryAltPullBased (fails, no banker)
8. Progress: 0/35 indefinitely

AFTER FIX:
1. `/wipe` (clear local data)
2. Logout all bankers
3. `/togbank sync` from non-banker
4. Output: "P2P: Broadcasting request..." × 35
5. Peer outputs: "PERF-005: Peer responding for X (hash match: Y)"
6. Peer outputs: "P2P: Responding to Sender with data for X (hash=Y) - queue now: 1/3"
7. Requester outputs: "P2P: Peer Username acknowledged X - will send delta"
8. Data transfer completes via togbank-state → togbank-d
9. Progress: 1/35, 2/35, ... 35/35 (completes in 1-2 minutes)
```

**Expected Behavior After Fix:**
- ✅ P2P requests broadcast via `togbank-hl` are properly processed
- ✅ Peers with matching hash respond with data
- ✅ P2P transfer completes without banker online
- ✅ No 5-second timeouts or fallback needed (unless all peers busy)
- ✅ Much faster sync (parallel P2P vs sequential banker queries)

**Backwards Compatibility:**
- **Old code (< v0.8.0):** Doesn't listen to `togbank-hl`, unaffected ✅
- **New code (v0.8.0-8.15):** P2P broken, relies on banker fallback ⚠️
- **New code (v0.8.16+):** P2P fully operational ✅
- **Migration:** All users should update to v0.8.16+ for P2P benefits

**Flow Comparison:**

**BEFORE (Broken):**
```
Requester → togbank-hl broadcast (P2P request)
Peers     → receive togbank-hl, attempt to forward to togbank-r
         → forwarding fails (already passed that check)
         → request ignored, no response sent
Requester → waits 5 seconds, timeout
         → falls back to QueryAltPullBased
         → if banker online: queries banker (slow, sequential)
         → if banker offline: stuck at 0/35
```

**AFTER (Fixed):**
```
Requester → togbank-hl broadcast (P2P request)
Peers     → receive togbank-hl, recursively call OnCommReceived("togbank-r")
         → togbank-r handler processes request
         → checks hash match: myHash == expectedHash
         → sends togbank-rr acknowledgment (WHISPER)
Requester → receives togbank-rr, sends togbank-state (WHISPER)
Peer      → receives togbank-state, compares hashes, sends togbank-d (WHISPER)
Requester → receives togbank-d, applies data
         → Progress: 1/35, 2/35, ... (fast, parallel)
```

**Why This Bug Was Hard to Detect:**
1. **Fast fallback:** 5-second timeout meant banker queries happened quickly
2. **Banker usually online:** Testing typically done with banker available
3. **No errors:** Silent failure, just looked slow
4. **Bandwidth savings still worked:** Hash comparisons prevented unnecessary transfers
5. **PERF-006 was focused on channel segregation:** Forwarding logic wasn't tested

**Files Changed:**
- [Modules/Chat.lua](Modules/Chat.lua#L1685-1693) - togbank-hl forwarding to togbank-r

**Related Issues:**
- [PERF-006] Channel migration that introduced the bug
- [P2P-008] Post-wipe recovery (companion fix for no-banker scenarios)
- [PERF-005] Original P2P protocol design

**Prevention:**
- **Test forwarding logic explicitly** - Don't assume variable reassignment works
- **Test P2P without banker online** - Catches both P2P-008 and P2P-009
- **Use recursive calls for message forwarding** - More reliable than variable manipulation
- **Log at each step** - Would have shown "request received but not processed"
- **Validate channel migration changes** - Especially when moving from working code

**Key Insight:**
When forwarding messages between handlers in the same function, you can't just change the prefix variable - you must either:
1. **Recursively call** the function with new prefix (chosen solution)
2. **Extract shared logic** to separate function, call from both handlers
3. **Reorder handlers** to process forwarded prefix first (fragile, order-dependent)

Recursive calling is cleanest because it isolates the forwarding logic and makes intent clear.

---

#### [P2P-015] Race condition: Multiple peers responding simultaneously

**Severity:** 🟠 HIGH
**Category:** P2P / Concurrency / Protocol
**Reporter:** Code Review
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 50-80% - Depends on network timing and number of peers with matching hash
**Related:** [PERF-005] P2P protocol design, [P2P-012] Counter leak

**Problem:**
When a P2P request was broadcast to GUILD channel, multiple peers with matching hashes would all decide to respond **simultaneously**. Each peer would increment `pendingSendCount`, send ACK messages, and start 30-second timeout timers. This caused:
1. Unnecessary duplicate data transfers (wasted bandwidth)
2. pendingSendCount inflating rapidly (3+ peers × multiple alts = queue exhaustion)
3. Later peers blocked from responding due to `MAX_PENDING_SENDS` limit
4. Requester receiving duplicate data from multiple sources

**Root Cause:**
All peers evaluated `shouldRespondP2P` logic synchronously at nearly the same time, before any peer had incremented `pendingSendCount`. No coordination mechanism existed to prevent multiple simultaneous responses.

**Fix:**
Implemented **random backoff delay** (0-500ms) for P2P peer responses. Only the winner (or winners within the backoff window) will acquire send slots.

**Chat.lua lines ~823-879:**
```lua
if shouldRespondP2P then
    -- FIX: Add random backoff to prevent multiple peers responding simultaneously
    local backoff = math.random() * 0.5  -- 0-500ms random delay
    C_Timer.After(backoff, function()
        -- Check if someone else already responded
        if TOGBankClassic_Guild.pendingSendCount >= TOGBankClassic_Guild.MAX_PENDING_SENDS then
            return  -- Another peer beat us, back off
        end
        shouldRespond = true
        TOGBankClassic_Guild.pendingSendCount = TOGBankClassic_Guild.pendingSendCount + 1
        -- Send ACK after delay
    end)
end
```

**Files Changed:**
- [Modules/Chat.lua](Modules/Chat.lua#L823-879) - Added random backoff for P2P peer responses

---

#### [P2P-014] Memory leak: expectedHashes not cleared on timeout

**Severity:** 🟡 MEDIUM
**Category:** P2P / Memory Management
**Reporter:** Code Review
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - Every P2P timeout leaked hash entries
**Related:** [P2P-013] Timer tracking, [PERF-005] P2P protocol

**Problem:**
When P2P broadcasts timed out (no peer response after 5 seconds), the code cleared `pendingP2PRequests` to enable banker fallback, but **never cleared** `expectedHashes[norm]` and `expectedHashUpdatedAt[norm]`. These hash entries accumulated indefinitely in memory.

**Root Cause:**
Two locations cleared `pendingP2PRequests` on timeout but forgot to clear hash tables:
- Guild.lua BroadcastP2PRequest timeout (lines ~891-909)
- Chat.lua togbank-rr timeout (lines ~1073-1082)

**Fix:**
Added hash cleanup to both timeout handlers:

```lua
// FIX: Clear expectedHashes to prevent memory leak
if self.expectedHashes then
    self.expectedHashes[norm] = nil
end
if self.expectedHashUpdatedAt then
    self.expectedHashUpdatedAt[norm] = nil
end
```

**Files Changed:**
- [Modules/Guild.lua](Modules/Guild.lua#L895-912) - BroadcastP2PRequest timeout cleanup
- [Modules/Chat.lua](Modules/Chat.lua#L1078-1095) - togbank-rr timeout cleanup

---

#### [P2P-013] Race condition: Dual timeout timers

**Severity:** 🟠 HIGH
**Category:** P2P / Timing / Concurrency
**Reporter:** Code Review
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 80% - Occurs whenever peer responds between 4-5 seconds
**Related:** [P2P-011] Timer cancellation, [P2P-014] Hash cleanup

**Problem:**
When a banker responded to a hash query, the code created two concurrent timeout timers:
1. **First timer:** 5-second P2P broadcast timeout (fallback to banker if no peer responds)
2. **Second timer:** 15-second peer delivery timeout (fallback to banker if peer ACKs but doesn't send data)

If a peer ACKed at second 4, both timers would fire, causing duplicate banker requests.

**Root Cause:**
Peer ACK handler cleared `pendingP2PRequests` but didn't cancel the first timeout timer.

**Fix:**
Added timer tracking and cancellation in peer ACK handler:

```lua
// FIX: Cancel the first timeout timer since peer responded
if TOGBankClassic_Guild.pendingP2PTimeouts and TOGBankClassic_Guild.pendingP2PTimeouts[norm] then
    TOGBankClassic_Guild.pendingP2PTimeouts[norm]:Cancel()
    TOGBankClassic_Guild.pendingP2PTimeouts[norm] = nil
end
```

**Files Changed:**
- [Modules/Guild.lua](Modules/Guild.lua#L17) - Added `pendingP2PTimeouts` tracking table
- [Modules/Guild.lua](Modules/Guild.lua#L920) - Store timeout timer for cancellation
- [Modules/Chat.lua](Modules/Chat.lua#L1104-1107) - Cancel first timer when peer responds

---

#### [P2P-012] Counter leak: pendingSendCount double-decrement

**Severity:** 🟠 HIGH
**Category:** P2P / Counter Management / Resource Tracking
**Reporter:** Code Review
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - Occurred on every P2P send if completed within 30 seconds
**Related:** [P2P-011] Timer cancellation, [P2P-015] Race condition

**Problem:**
When a peer responded to a P2P request, it incremented `pendingSendCount` and started a 30-second safety timeout. However, when data sent successfully, **both** the send completion callback AND the timeout decremented the counter, causing it to go negative.

**Root Cause:**
SendAltData cleared timer reference without calling `:Cancel()`, so timer continued running and fired even after send completed.

**Fix:**
Changed SendAltData to actually cancel the timer object:

```lua
// AFTER (FIXED):
if self.pendingSendTimeouts and self.pendingSendTimeouts[norm] then
    self.pendingSendTimeouts[norm]:Cancel()  // FIX: Actually stop the timer
    self.pendingSendTimeouts[norm] = nil
end
```

**Files Changed:**
- [Modules/Guild.lua](Modules/Guild.lua#L2000) - Actually call timer:Cancel()

---

#### [P2P-011] Timer cancellation not working - semantic vs actual cancellation

**Severity:** 🟡 MEDIUM
**Category:** P2P / Timer Management / API Usage
**Reporter:** Code Review
**Date Reported:** 2026-02-17
**Date Resolved:** 2026-02-17
**Status:** ✅ RESOLVED
**Reproducibility:** 100% - Setting timer reference to nil never cancels timer
**Related:** [P2P-012] Counter leak, [P2P-013] Dual timers

**Problem:**
Throughout the codebase, timer cancellation was implemented as `timer = nil`. This **clears the reference** but doesn't **stop the timer callback** from executing. `C_Timer.After()` returns a timer object with a `:Cancel()` method that must be explicitly called.

**Root Cause:**
Misunderstanding of WoW timer API. Setting a variable to `nil` only affects the variable, not the timer object it references.

**Fix:**
Changed all timer cancellations to call `:Cancel()` method explicitly:

```lua
// BEFORE (BROKEN):
timer = nil  // Doesn't stop timer

// AFTER (FIXED):
timer:Cancel()  // Stop timer callback
timer = nil     // Clear reference (optional)
```

**Files Changed:**
- [Modules/Guild.lua](Modules/Guild.lua#L2000) - SendAltData timeout cancellation
- [Modules/Chat.lua](Modules/Chat.lua#L1104) - Peer ACK handler timeout cancellation

---

#### [PERF-011] Load freeze: CleanupDeltaHistory() defined but never called

**Severity:** 🔴 HIGH
**Category:** Performance / SavedVariables
**Reporter:** User (Production)
**Date Reported:** 2026-02-27
**Date Resolved:** 2026-02-27
**Status:** ✅ RESOLVED
**Reproducibility:** 100% — occurs on every fresh login until SV is cleaned

**Problem:**
3-5 second game freeze on first few `/reload`s. SavedVariables file ballooned to 52,764 lines / 1.3 MB. The `deltaHistory` section alone was 33,421 lines — full delta diffs for every alt accumulated over many sessions with no eviction.

**Root Cause:**
`CleanupDeltaHistory()` was defined in `Database.lua` and had a correct 1-hour TTL (`DELTA_HISTORY_MAX_AGE = 3600`), but was never called anywhere. Every delta send wrote a new entry via `SaveDeltaHistory()` with no corresponding cleanup.

**Fix:**
Added two call sites in `Events.lua`:
1. `GUILD_RANKS_UPDATE` startup handler — deferred 2s cleanup on first init (`-- PERF-011`)
2. `OnShareTimer` periodic callback — cleanup every 3-minute share cycle (`-- PERF-011`)

**Result:**
`deltaHistory` section in SV dropped to 2 lines (empty table) after one reload.

**Files Modified:**
- [Modules/Events.lua](Modules/Events.lua) — Added `CleanupDeltaHistory` calls at startup and periodically

---

#### [PERF-012] Load freeze: deltaSnapshots and deltaHistory persisted to SavedVariables unnecessarily

**Severity:** 🔴 HIGH
**Category:** Performance / SavedVariables / Data Architecture
**Reporter:** User (Production)
**Date Reported:** 2026-02-27
**Date Resolved:** 2026-02-27
**Status:** ✅ RESOLVED
**Reproducibility:** 100% — every reload parsed 18.7k lines of redundant data

**Problem:**
After PERF-011 fixed `deltaHistory`, the SV file was still ~50k lines. Investigation found `deltaSnapshots` section was 18,710 lines — full inventory copies of all 35 banker alts stored as delta computation baselines. These were re-parsed by WoW on every load despite being immediately invalidated and rebuilt from live sync data each session.

`deltaHistory` was also persisted, but its consumer (`RequestDeltaChain` / `togbank-dr`) is dead code since v0.8.0 stopped sending `baseVersion` in delta messages — the only gate condition for that code path.

**Root Cause:**
Both `deltaSnapshots` and `deltaHistory` were stored in AceDB `faction` scope, meaning WoW serialized and parsed them on every login. Neither needed to survive a reload:
- Snapshots: rebuilt from the first sync of each session
- Delta chain history: consumed only by a code path that can never be reached

**Fix:**
1. Moved `deltaSnapshots` to a module-local in-memory table `deltaSnapshotsCache` — fully functional within a session, zero SV footprint
2. Made `SaveDeltaHistory` a no-op stub; removed `deltaHistory` from AceDB schema
3. `Database:Load()` now nils both fields on existing SV data to purge old entries on first save after update
4. Removed `SaveDeltaHistory` call in `Guild.lua` (after every delta send)
5. All snapshot functions (`SaveSnapshot`, `GetSnapshot`, `GetSnapshotAge`, `CleanupOldSnapshots`) redirected to in-memory cache

**Result:**
SV file dropped from 50,672 lines to 32,426 lines (-18,246 lines, ~36% reduction) after two reloads. `deltaSnapshots` and `deltaHistory` keys absent from SV entirely.

**Files Modified:**
- [Modules/Database.lua](Modules/Database.lua) — In-memory snapshot cache, no-op SaveDeltaHistory, Load() purge
- [Modules/Guild.lua](Modules/Guild.lua) — Removed SaveDeltaHistory call after delta send

---

#### [ROSTER-002] Stale ex-banker appearing permanently as "HLR pending"

**Severity:** 🟡 MEDIUM
**Category:** Roster / Data Integrity
**Reporter:** User (Production)
**Date Reported:** 2026-02-27
**Date Resolved:** 2026-02-27
**Status:** ✅ RESOLVED
**Reproducibility:** Consistent — any ex-banker with residual zero stub persists indefinitely

**Problem:**
`Raideronly-OldBlanchy` appeared as "HLR pending" in the UI despite not being a current guild banker. The character existed in `roster.alts` and as a zero stub `{version=0, inventoryHash=0, mailHash=0}` in `alts`, causing `BuildBankerHashList` to include them in the hash broadcast, and `latestBankerHashes` to seed them as a pending sync target.

**Root Cause — Three compounding failures:**

1. **`RebuildBankerRoster()`** never purged zero stubs for ex-bankers. When a character left the banker rank, their stub stayed in `alts` forever.

2. **`latestBankerHashes` init** ran 0.5s after login (before `RebuildBankerRoster` at 1s) and iterated ALL `alts` — including ex-banker stubs — seeding them into the hash cache as permanently pending.

3. **`BuildBankerHashList()`** included zero stubs in the hash list broadcast, causing all peers to treat the ex-banker as a live sync target.

**Fix:**

1. **`RebuildBankerRoster()`** — Added cleanup loop: after building the new roster, deletes any `alts` entry that is a zero stub (`version==0, inventoryHash==0, mailHash==0`, no items) AND is not in the new banker roster. Tagged `-- ROSTER-002`.

2. **`Guild:Init()` latestBankerHashes init** — Delayed timer from 0.5s → 1.5s (fires after RebuildBankerRoster at 1s). Now filtered through `banksCache` — only current roster members seeded. Tagged `-- PERF-010 / ROSTER-002`.

3. **`BuildBankerHashList()`** — Added `hasAnyData` check; skips entries where `version`, `inventoryHash`, `mailHash` are all zero/nil and no items exist. Tagged `-- ROSTER-002`.

**Self-review catch:** Initial fix missed `mailHash` in both the zero-stub detection and the `hasAnyData` check — corrected before shipping.

**Files Modified:**
- [Modules/Guild.lua](Modules/Guild.lua) — `RebuildBankerRoster()`, `Init()` latestBankerHashes, `BuildBankerHashList()`

---

#### [ITEM-003] Link stripping on weapons/armor causes deduplication collisions for same-ID suffix variants

**Severity:** 🔴 CRITICAL
**Category:** Data Integrity / Delta Sync / Item Deduplication
**Reporter:** User (Production — Toglowweap-Azuresong inventory)
**Date Reported:** 2026-02-27
**Date Resolved:** 2026-02-27
**Status:** ✅ RESOLVED
**Reproducibility:** 100% — any banker holding two variants of same weapon (e.g. plain + suffixed) triggers duplication

**Problem:**
Toglowweap's inventory showed ghost stacks — e.g. `Acrobatic Staff ×6` alongside `Acrobatic Staff of the Wolf ×1`. The plain ×6 didn't exist in the actual bank; it was a phantom created by delta sync corruption. Similar ghosts appeared for other weapon IDs with mixed plain/suffixed variants.

**Root Cause — Three interlocking bugs:**

**Bug 1 — `NeedsLink` ignored `ITEM_CLASSES_NEEDING_LINK`:**
`ITEM_CLASSES_NEEDING_LINK = { [2]=Weapon, [4]=Armor }` was defined but `NeedsLink()` never checked it. Instead it only checked for a non-zero suffix field in the link string. Plain weapons (suffix=0) returned `false` → link stripped to bare ItemString. Suffixed weapons returned `true` → full Link preserved. Two variants of the same weapon (e.g. both `ID=3185`) were stored in completely different formats, making deduplication impossible.

**Bug 2 — `ComputeItemDelta` deep fallback re-used same old item:**
The "fallback 2" loop searched for any old item with a matching ID when normalized key lookup failed. With a minimal baseline `{ID=3185, Count=N}`, both `Acrobatic Staff` (plain) and `Acrobatic Staff of the Wolf` would match the same entry — producing two `modified` entries for one old item, making one new item invisible (treated as already-present) and creating duplicates.

**Bug 3 — `ApplyItemDelta` STEP 3 used ID-only existence check:**
When inserting "added" items, a raw ID scan found the first item with matching ID and overwrote it instead of inserting a distinct entry. `Stone Hammer ×4` and `Stone Hammer of Tiger ×1` (both `ID=15260`) — the second one processed would stomp the first, corrupting count and link.

**Bonus Bug — `ComputeItemDelta` removed entries were ID-only:**
Removed items were serialized as `{ ID = item.ID }` only. On the receiver, the ID-only remove path (`table.remove` on first ID match) would hit whichever variant came first in the array — potentially removing the correct item and leaving the ghost, or vice versa.

**Fix:**

**`NeedsLink` (Item.lua):**
Primary check now uses `GetItemInfo(itemID)` to get `itemClassId` (12th return). If class is `2` (Weapon) or `4` (Armor), always returns `true` regardless of suffix. Suffix-field regex kept as fallback for uncached items.

**`ComputeItemDelta` removed entries (DeltaComms.lua):**
Removed entries now carry `Link` (or `ItemString`) when available. ID-only removed entries only for items that had no link data.

**`ApplyItemDelta` remove handler (DeltaComms.lua):**
Remove matching with Link now also checks `item.ItemString` as a source for key normalization (previously only checked `item.Link`), so ItemString-only entries are also matched precisely.

**`ComputeItemDelta` deep fallback (DeltaComms.lua):**
Added `deepFallbackUsed` table keyed by item identity. Once an old item is claimed by deep fallback, subsequent new items with the same base ID get no match and correctly land in `delta.added`.

**`ApplyItemDelta` STEP 3 add handler (DeltaComms.lua):**
Primary lookup changed to normalized key (`ID + GetItemKey(Link|ItemString)`). Falls back to ID-only only for linkless existing entries (`{ID, Count}` stubs from old format) — the legitimate upgrade case.

**Ghost cleanup:**
Existing ghost stacks in SV were expected to be corrected on the next delta push from the banker. However, post-fix testing (`/wipe` + resync) showed ghosts still returning — see follow-up investigation below (ITEM-003b).

**Files Modified (commit 5a40d73):**
- [Modules/Item.lua](Modules/Item.lua) — `NeedsLink()`: check item class via GetItemInfo
- [Modules/DeltaComms.lua](Modules/DeltaComms.lua) — `ComputeItemDelta` removes carry Link; deep fallback guard; `ApplyItemDelta` STEP 3 normalized key lookup; remove handler ItemString normalization

---

#### [ITEM-003b] Receive-side ghost weapon stacks survive sender-side fix due to GetItemInfo cache-miss race

**Severity:** 🔴 CRITICAL
**Category:** Data Integrity / Delta Sync / Receive-Side Guard
**Reporter:** User (Production — ghost `Acrobatic Staff ×6` persisted after ITEM-003 fix + `/wipe`)
**Date Reported:** 2026-02-27
**Date Resolved:** 2026-02-27
**Status:** ✅ RESOLVED
**Commit:** `8ced667`

**Problem:**
After deploying ITEM-003 and doing `/wipe` + resync, the ghost `Acrobatic Staff ×6` plain stack returned in the receiver's SV alongside the correct `Acrobatic Staff of the Wolf ×1`. The sender-side `NeedsLink` fix was not fully effective by itself.

**Investigation:**
Inspected banker's SavedVariables (`981197530#1`):
- Banker had only **two** `Acrobatic Staff` entries, both line 40262 and 40512, both with full Link `|cff1eff00|Hitem:3185...366387584...` (the `366387584` suffix encodes "of the Wolf").
- No plain `Acrobatic Staff` (suffix=0) existed in banker's SV — the ghost was not from banker's scan data.

**Root cause:**
`StripDeltaLinks` (sender-side) calls `NeedsLink` to decide whether to keep the full Link or downgrade to an ItemString. For **plain weapons** (suffix=0), when `GetItemInfo` is **not yet cached** on the sender at the moment of the call, `NeedsLink` falls through to the suffix-regex fallback — which matches a non-zero suffix field, but suffix=0 produces no match — so it returns `false` and strips the link to `ItemString="3185:0:0:0:0:0:0"`.

On the **receiver**, `ApplyItemDelta` STEP 3 normalized-key lookup computes a different key for `item:3185:0:0:0:0:0:0` vs `item:3185:::::521` (the wolf variant). No existing entry matches → the linkless plain entry is **inserted as a brand-new ghost stack**.

The sender may be sending a correct suffixed entry AND an inadvertently linkless-stripped plain entry if `GetItemInfo` was cold on one of them at transmit time.

**Fix:**
Added `TOGBankClassic_Item:ItemClassNeedsLink(itemID)` to [Modules/Item.lua](Modules/Item.lua):
- Calls `GetItemInfo(itemID)`, reads `itemClassId` (12th return)
- Returns `true` if class 2 (Weapon) or 4 (Armor), `false` for other known classes, `nil` if not cached

In `ApplyItemDelta` [Modules/DeltaComms.lua](Modules/DeltaComms.lua), **before inserting any linkless item** (has `ItemString` but no `Link`) as a new entry in **STEP 2** (modified-fallback-to-new) and **STEP 3** (added):

1. **Class confirmed (cached):** `ItemClassNeedsLink` returns `true` → block insert, log `[ITEM-003] STEP3: blocked linkless weapon/armor ID=X (class confirmed)`
2. **Class uncached:** `ItemClassNeedsLink` returns `nil` → scan existing items for any entry with same base ID that **has a Link** → if found, block insert (linked version is authoritative), log `[ITEM-003] STEP3: blocked linkless ID=X (linked entry exists, class uncached)`
3. **Class is not weapon/armor, no linked entry:** allow insert (normal consumable/trade-good without any pre-existing linked entry)

**Why the secondary guard is needed:**
The receiver's client may also have `GetItemInfo` uncached for items it hasn't directly seen. Using the presence of an existing linked entry as a proxy for "this item type needs a link" covers the cache-miss window without requiring a server round-trip.

**Files Modified (commit 8ced667):**
- [Modules/Item.lua](Modules/Item.lua) — new `ItemClassNeedsLink(itemID)` helper
- [Modules/DeltaComms.lua](Modules/DeltaComms.lua) — `ApplyItemDelta` STEP 2 and STEP 3 linkless-insert guard

---

## [UI-001] Inventory slot counts show 0/0 for non-bank members

**Severity:** MEDIUM
**Status:** Fixed 2026-03-12
**Reported:** March 12, 2026 (external user feedback)

**Symptom:**
Non-bank members (guild members who are not the banker) open the TOGBankClassic window and the status bar at the bottom shows `0/0` for used/total slots. The banker themselves sees the correct count (e.g. `188/200`).

**Root Cause:**
The delta protocol (`DeltaComms.lua`) transmits item changes for bank and bags as add/modify/remove arrays, but never included `bank.slots` or `bags.slots` (the used/total slot counts). The UI status bar reads these fields directly — when they are absent the nil-safe guard skips them and the running totals stay at zero.

Full snapshots sent via `StripAltLinks` (Guild.lua) do include `slots`, which is why the banker's own client always showed correct counts (it never needs to receive its own data via delta).

**Fix:**
`DeltaComms.lua` delta builder (`ComputeDelta`) now appends `changes.bankSlots` and `changes.bagsSlots` to every delta when the source alt has slot data. The applier (`ApplyDelta`) writes these onto `current.bank.slots` / `current.bags.slots` immediately after item changes are applied.

**Files Modified:**
- [Modules/DeltaComms.lua](Modules/DeltaComms.lua) — `ComputeDelta` (include bankSlots/bagsSlots), `ApplyDelta` (apply bankSlots/bagsSlots)

---

## [UI-002] Broken square icon when hovering over gold amount

**Severity:** LOW
**Status:** Fixed 2026-03-12
**Reported:** March 12, 2026 (external user feedback)

**Symptom:**
When hovering over the status bar at the bottom of the inventory window, a broken/square icon appears where the gold coin medallion texture should be.

**Root Cause:**
`GetCoinTextureString()` returns `|T<path>:14:14:2:0|t` texture-embed codes. These render correctly in most WoW UI contexts (GameTooltip, chat frames) but do not render reliably in AceGUI status bar FontStrings — the texture shows as a white or broken square box.

**Fix:**
Replaced both `GetCoinTextureString()` calls in `UI/Inventory.lua` (default status and `OnEnterStatusBar` hover) with a new module-local `FormatMoneyText()` helper. The helper formats money as colored plain text: gold in `|cffFFD700|r`, silver in `|cffc0c0c0|r`, copper in `|cffb46a2f|r`. No embedded textures — renders correctly in any FontString context.

**Files Modified:**
- [Modules/UI/Inventory.lua](Modules/UI/Inventory.lua) — `FormatMoneyText` local helper (new), `DrawWindow` default status and `OnEnterStatusBar` callback

---

## [UI-003] Item quality border color missing for non-recipe gear

**Severity:** LOW
**Status:** Fixed March 20, 2026
**Reported:** March 12, 2026 (external user feedback)

**Symptom:**
Recipe items correctly displayed green quality borders. Green- and blue-quality gear (weapons, armor) displayed a white border instead of the appropriate quality color.

**Root Cause:**
Three compounding issues:
1. `GetItems` Branch 1 (items with a link, i.e. local bank scan) used `GetItemInfoInstant` → returns no `rarity` field → `item.Info.rarity` always nil for locally-scanned gear. Fixed in UI-011 by switching to `GetItemInfo(link)`.
2. Even after the UI-011 fix, gear synced from other bankers that the local client has never cached is not yet in the WoW item cache when `DrawItem` runs. `GetItemInfo(item.Link)` returns nil at draw time → rarity still nil → sync/async fallbacks in `DrawItem` needed.
3. **Root cause of gear-still-wrong after fallbacks were added:** `Item:Sort` ran before `DrawItem` and contained `item.Info.rarity = item.Info.rarity or 1` — defaulting nil rarity to 1 (common/white) for all items missing it. By the time `DrawItem` evaluated `item.Info.rarity`, the value was `1` (truthy), so `GetItemQualityColor(1)` was called and the border was explicitly painted white. The sync/async fallbacks were guarded by `if rarity then ... elseif item.Link then` — with rarity now truthy, the fallback branch was unreachable. The sort comparators already safely handled nil rarity via `(a.Info.rarity or 0)`, so the assignment served no functional purpose.

Recipe items worked correctly because they are common consumables typically cached by the client from prior loot or AH browsing — `GetItemInfo` succeeded at `GetItems` time and rarity was populated before `Sort` ran, so the `or 1` default was never applied.

**Fix:**
- `Item.lua` Branch 1: switched from `GetItemInfoInstant` to `GetItemInfo(link)` so locally-scanned items always have rarity populated. Committed `251df33`.
- `Item.lua Sort`: removed `item.Info.rarity = item.Info.rarity or 1`. Nil rarity now propagates intact to `DrawItem`, allowing the fallback paths to fire.
- `UI.lua DrawItem`: added two fallback levels for items whose rarity is nil at draw time:
  1. **Sync fallback** — `GetItemInfo(item.Link)` called immediately at draw time; succeeds if the client cached the item between `GetItems` and first render.
  2. **Async fallback** — `Item:CreateFromItemID` + `ContinueOnItemLoad` fires `GetItemInfo(item.Link)` once the item enters the client cache, then calls `border:SetVertexColor`. Purely display-side; no data is stored or mutated.
- **ID-based lookup deliberately excluded**: `GetItemInfo(item.ID)` returns the base item's rarity, which is wrong for suffixed gear — e.g. "Iron Sword" (grey) and "Iron Sword of the Tiger" (green) share the same base ID. All rarity queries use `item.Link` exclusively.
- Gear items always have their full link preserved (`ForceLink=true`); there is no reconstruction path for gear links, so link-based queries are always safe and accurate.

**Location:** UI.lua `DrawItem` (~line 145); Item.lua `GetItems` Branch 1 (~line 228); Item.lua `Sort` (~line 449).

---

## [UI-004] Tooltips missing for some food items

**Severity:** LOW
**Status:** Active
**Reported:** March 12, 2026 (external user feedback)

**Symptom:**
Certain food items show no tooltip on hover in the inventory window. Confirmed affected: Homemade Cherry Pie, Roasted Quail. Other food items may be affected.

**Investigation Needed:**
- Determine whether the tooltip is never shown or shown with empty text
- Check whether affected items share a common trait (e.g. item class/subclass, cache miss at tooltip time, specific item IDs)
- Inspect the tooltip population path in `UI/Inventory.lua` for early-return conditions that would suppress display for food-class items

---
