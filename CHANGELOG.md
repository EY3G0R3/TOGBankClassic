# TOGBankClassic Changelog

## [v1.1.4] (2026-05-30) - Re-open Orders, Multi-Order Mail & Fulfillment Fixes

### New Features

- **REOPEN-001: Re-open a finished order** — A banker, officer, or GM can now re-open a completed order (filled, manually-completed, or cancelled) from the Requests window, in case it was marked done by mistake. A re-open icon appears on finished rows for those roles; confirming resets the order to `open`, clears its Sent count, and drops any cancel reason. New `Guild:ReopenRequest(requestId, actor)` (gated by `CanManageRequests` = banker/officer/GM), a `reopen` mutation type, and an optional `reopenedAt` field appended to the request record and the `togbank-rd2` wire format (slot 14, append-only). The request log normally *ratchets* terminal statuses — it refuses to un-cancel/un-complete an order during sync so a stale fulfillment can't revert a finished order — so the re-open carries a `reopenedAt` timestamp and a narrow exception in `mergeRequest` lets a re-open stamped *after* the terminal defeat the ratchet, so it survives sync instead of snapping back to done. Older clients (pre-REOPEN-001) keep the order terminal until they update. Locations: `Modules/RequestLog.lua` (`ReopenRequest`, `mergeRequest` ratchet exception, `ApplyRequestMutation` `reopen` auth, wire serialize/deserialize/sanitize), `Modules/UI/Requests.lua` (re-open button + confirm dialog).

### Bug Fixes

- **COMPLETEQTY-002: Manual "Mark Filled" hand-off didn't complete the order** — The row check-mark button (manual completion, for items handed over in person or mailed yourself) opened a quantity prompt whose confirm button read "Mark Sent", but entering the amount and confirming often left the order unchanged. The prompt routed through the by-name `FulfillRequest(bank, requester, item, …)` path, which re-matches the request on bank + requester + item and silently no-ops if any field doesn't compare equal — so nothing was recorded and the order stayed open (only a quiet "Unable to record that quantity." status line). It now completes the request **by its id** via the new `Guild:FulfillRequestById(requestId, count, actor)`: the amount is recorded into the Sent column and, once Sent reaches the requested quantity, the order is closed outright (status `complete`, broadcast as a full snapshot so peers replicate the Sent total and terminal status); a partial amount records the Sent total and leaves the order open. The confirm button is relabelled **"Mark Filled"** (covers both an in-person hand-off and mail you sent yourself) and the prompt wording generalised to match. Locations: `Modules/RequestLog.lua` (`FulfillRequestById`), `Modules/UI/Requests.lua` (prompt text, button label, OnAccept).

- **HITBOX-002: Bottom-row icons still dead in their bottom half (HITBOX-001 follow-up)** — The HITBOX-001 lift (v1.1.2) raised each bottom-row icon to `window.frame:GetFrameLevel() + 10` once, at construction time. But the Inventory/Search/Requests windows are `FULLSCREEN_DIALOG` AceGUI frames whose frame level jumps to a much higher value when they are *shown*; AceGUI's `sizer_s` resize strip tracks the parent up to `parentLevel + 1`, while the icons stayed pinned at the stale construction-time level — so once shown, the sizer sat back above the icons and swallowed clicks/hover across the bottom ~half of every bottom-row control (and AceGUI's own Close button, which HITBOX-001 never lifted at all). Fixed with a shared helper `TOGBankClassic_UI:KeepAboveResizeSizers(window, buttons)` that re-asserts the lift against the *live* parent level on every `OnShow` (plus a next-frame pass, since the final level lands just after OnShow), and that also locates and lifts AceGUI's Close button. The button set is stored on the frame and the `OnShow` hook is attached once per frame, so the Requests window's release/reacquire (banker-status change) and AceGUI's frame pooling neither stack hooks nor lift recycled buttons. Locations: `Modules/UI.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.

### Improvements

- **MULTIORDER-001: One mail can close several of a person's orders** — When a banker mails items to a guild member, the addon now credits *every* matching open order that member has with that banker, instead of only one. A fully manual mail already spread across multiple orders (matched by item name); this extends the same behaviour to addon-generated mails: if the banker uses the Fulfill button and then hand-attaches extra items to "save a mail," `OnSendMail` diffs the actual attachments against what the addon attached and records the surplus as `pending.extraItems`, and `ApplyPendingSend` credits the button's targeted order via the request's own stored item name (locale-safe, by `requestId`), then spills the hand-added extras across the recipient's other open orders by name. The addon's `pending.items` is deliberately **not** overwritten with `GetSendMailItem` names (the banker's client locale), which would break the targeted match in a mixed-locale guild. Orders assigned to a *different* banker are left untouched. Locations: `Modules/Mail.lua` (`OnSendMail`, `ApplyPendingSend`).

## [v1.1.3] (2026-05-30) - Cancel-Stale Broom Icon Hotfix

### Bug Fixes

- **BROOM-001: Cancel-Stale button was invisible** — The broom icon shipped in v1.1.2 used `Interface\Icons\INV_Broom_01`, which does not exist in the Classic Era client (it rendered as the blue missing-texture box, so the bulk-cancel button appeared blank). `INV_Misc_Broom_01` and `INV_Pet_Broom` are likewise absent from the Era texture set — Classic Era ships no broom icon at all. Fixed by bundling a custom broom texture with the addon (`Textures/broom.tga`, a 64×64 32-bit TGA with alpha) and pointing the Cancel-Stale button at it via addon path (`Interface\AddOns\TOGBankClassic\Textures\broom`), so the icon renders regardless of which icons the client happens to include. The new `Textures/` folder ships in the build; its spec note (`Textures/README.md`) is excluded via `.pkgmeta`. Location: `Modules/UI/Requests.lua`, `Textures/broom.tga`, `.pkgmeta`.

## [v1.1.2] (2026-05-30) - Requests Tabs, Custom Cancel Reasons & Armor Slot Filter

### New Features

- **REQUI-001: Officer-only Settings tab in the Requests window** — Added a third tab, `Settings`, to the Requests window, visible only to the GM and officers (gated on `CanViewOfficerNote()`). It renders as an opaque overlay panel over the request list with three editable numeric fields — Archive threshold (days), Auto-cancel stale (days), and Maximum request amount (%) — mirroring the three controls previously reachable only via the Blizzard options panel. Each field commits on Enter or focus-loss and only acts when the value actually changed, so unchanged focus-loss no longer re-broadcasts. The two guild-synced settings reuse the existing `TOGBankClassic_Guild:BroadcastSettings("ALERT")` path (SETTINGS-001), so changes propagate guild-wide exactly as the options panel does. New methods `BuildSettingsPanel`, `PopulateSettings`, `ShowSettings`. Location: `Modules/UI/Requests.lua`.
- **CANCELREASON-001: Custom guild cancel reasons (officer-authored, guild-synced)** — The officer Settings tab now includes a cancel-reason editor styled after the FastGuildInvite Filters tab: a `[Member] [Banker] [reason text] [Save]` strip over a banded, scrolling list. Officers add custom reasons and tick **Member** and/or **Banker** to choose whether each appears in the member self-cancel dropdown, the banker-cancel dropdown, or both. The built-in flavor presets also appear in the list, greyed/read-only (no edit, no delete), each with a single native-role tick officers can clear to stop offering that preset. Custom rows are click-to-edit and have a delete `X`. The whole config lives in `Info.settings.cancelReasons` (`{ custom = { {text, member, banker} }, presetDisabled = { banker = {key=true}, member = {key=true} } }`) and rides the existing `BroadcastSettings` path, so every member's cancel dialog offers the same reasons. Non-officers never see the editor (Settings tab is officer-only) but consume the synced reasons. The cancel dialog now builds its list from `buildPresetReasons(role)` minus `presetDisabled`, plus enabled customs for that role, and always offers at least one option. New methods `BuildReasonsEditor`, `RefreshReasonsList`, `_BuildReasonRow`, `_ConfigureReasonRow`, `_OnReasonToggle`, `_OnReasonDelete`, `_OnReasonEdit`, `_EnsureReasonConfig`. Locations: `Modules/UI/Requests.lua`, `Modules/Guild.lua`, `Modules/Database.lua`.

- **FILLALL-001: "Fulfill Oldest Order" stepped button (spam-to-fill)** — A new envelope icon in the Requests window's bottom-right cluster (bankers only) walks the **oldest order you can fully fill from your bags** through one action per click: select (sets the recipient, switches to the Send Mail tab) → **split** (only if a stack split is needed) → **attach** → **send**, then the next click picks the next-oldest. One WoW action per frame deliberately — the earlier single-click version raced the send ahead of the async split; stepping it lets the cursor/bag state settle between actions. The split commits into a free bag slot as its own stack (like the manual split), and ATTACH waits for it to land before grabbing it. Oldest-first (FIFO by `date`, with a stable request-id tiebreak so same-second orders pick deterministically instead of appearing to jump around the list) so item contention favours whoever asked first; only orders assigned to your own character are eligible (that's the constraint for fulfillment credit). **Mail collect:** if the oldest serviceable order's items are sitting in your mail inbox (not bags), each click first pulls one matching item into your bags (`TakeOneInboxItemFor`, gated on free bag space) until enough is collected, then it selects + fulfills — so the flow now spans bags **and** mail, only matching your own open orders. Orders you can't cover from bags + mail are skipped. After a send, a `batchInFlight` guard blocks re-selecting that order until the send confirms (cleared on `MAIL_SEND_SUCCESS`/`ApplyPendingSend`, mail error/`UI_ERROR_MESSAGE`, or a 5s safety timer); the step state resets on `MAIL_CLOSED`. The status bar shows the next step at each click. New `TOGBankClassic_Mail:FulfillStep` / `FindOldestServiceableOrder` / `TakeOneInboxItemFor` / `ResetFulfillStep` (+ inbox-match helpers), reusing `CalculateFulfillmentPlan` + the existing `pendingSend` → `FulfillRequest` path. `SendMail` added to `.luarc.json`. Locations: `Modules/Mail.lua`, `Modules/UI/Requests.lua`, `Modules/Events.lua`.
- **COMPLETEQTY-001: "Complete" now asks how much was handed over** — The row's check-mark button (for items given directly, not mailed) used to silently mark the whole request complete. It now opens a quantity prompt; the number you enter is recorded in the **Sent** column via `Guild:FulfillRequest(request.bank, …)`, and the order only flips to fulfilled once Sent reaches the amount requested — so partial hand-offs are tracked correctly. New `TOGBankClassic_CompleteQty` static popup (`hasEditBox`, numeric) + `showCompleteQtyPrompt`/`ensureCompleteQtyDialog`; applied against the request's own bank so it works whoever clicks (button visibility still gated by `CanCompleteRequest`). Location: `Modules/UI/Requests.lua`.
- **HELPNOTE-001: Officer help notes on the help (?) tooltips** — GM/officers can now add a custom note that appends to the bottom of the help "?" tooltip on each of the three windows (Inventory, Search, Requests) — e.g. how to submit a request and expected turnaround time. Edited in the Blizzard options panel (Esc → Options → AddOns → TOGBankClassic → Requests → "Guild Help Notes"), per window, as multi-line inputs gated to `CanViewOfficerNote()`. Stored in `Info.settings.helpNotes = { inventory, search, requests }`, synced guild-wide over the existing `BroadcastSettings` path (sanitized on receive by `SanitizeHelpNotes`, clamped to 400 chars/window). The tooltips read the note at hover time via a shared `TOGBankClassic_UI:AppendGuildHelpNote(windowKey)` (Inventory/Requests call it directly; Search passes a note key to `AttachTooltip`). New `TOGBankClassic_Guild:GetHelpNote`, `TOGBankClassic_Options:SetHelpNote`. Locations: `Modules/Guild.lua`, `Modules/Database.lua`, `Modules/Options.lua`, `Modules/UI.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.
- **VIEWBANK-001: View-only bank toons (visible but not requestable)** — A bank character can now be flagged "view only" so its stock stays visible everywhere (inventory, search, item tooltips) while guild members are blocked from sending requests for it — e.g. a raid bank. Officers flag it by adding a view-only marker to the toon's guild note alongside the usual `gbank` tag: `gbank viewonly` (also accepted: `view-only`, `readonly`, `read-only`, or the compact `gbankro`). New `TOGBankClassic_Guild:IsViewOnlyBank(name)` (O(1) via a `viewOnly` flag stored on `memberRoster`, computed from notes in `RefreshOnlineCache`/`RebuildBankerRoster`, with a roster-scan fallback). Enforced in three places: `Guild:AddRequest` hard-rejects any request whose target `bank` is view-only; the Search request dialog (`ShowRequestDialog`) refuses to open for a view-only banker and prints a reason; and Search result rows tag view-only banks with a `(view only)` marker. Items on both a normal and a view-only banker stay requestable from the normal one (requests are per-banker). Locations: `Modules/Guild.lua`, `Modules/RequestLog.lua`, `Modules/UI/Search.lua`.

### Bug Fixes

- **HITBOX-001: Bottom-row icons only clickable in a center sliver (clicks *and* tooltips)** — The gear, help `?`, `<` / `>` page arrows, broom, and fulfill envelope icons that sit along the bottom edge of the Inventory, Search, and Requests windows responded to clicks and hover only in a tiny center spot. Cause: AceGUI's `Frame` widget lays an invisible, mouse-enabled **resize strip** (`sizer_s`, full bottom width, 25px tall) plus a corner sizer across that whole row for the drag-to-resize handle. The parent frame is at frame level 100, so the sizers — and any icon added as a child of the same frame — all default to level **101**; two mouse-enabled frames overlapping at the *same* level produce ambiguous hit-testing, so the sizer swallowed most of each icon's input. Fixed by lifting every bottom-row icon to `window.frame:GetFrameLevel() + 10` (level 110) so it sits above the sizers and the full icon is live for both clicking and mouseover. Not a texture/`SetSize`/`SetHitRectInsets` issue (the gear's hit-rect was already *expanded* and still failed). Locations: `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.
- **FILLALL-002: Mail collect over-pulled stackable items** — The "Fulfill Oldest Order" mail-collect step counted *attachments* pulled rather than *items*, so for a stackable item (where one mail attachment can be a whole stack) it kept pulling past the amount needed and filled your bags. `TakeOneInboxItemFor` now returns the quantity taken (via `GetInboxItem`) and the collector tracks items pulled against the deficit, stopping once enough is in your bags — correct for both single items (1 = 1) and stacks. Location: `Modules/Mail.lua`.
- **REQUI-005: Pagination "snapped back" to the first page** — Clicking the `<` / `>` page arrows would jump back to page 1 a split second later. A background request sync (`RefreshRequestsUI` → `DrawContent`) was unconditionally resetting `currentPage = 1` on every redraw. `DrawContent` now resets the page only when the active tab actually changed (tracked via `_lastDrawnTab`), and `DrawRows` clamps `currentPage` to the valid range so a shrinking data set can't strand the view on an empty page. Location: `Modules/UI/Requests.lua`.

### Improvements

- **OFFICERTAB-001: Options "Requests" group renamed to "Officer" and gated to officers only** — The Blizzard options group (Esc → Options → AddOns → TOGBankClassic) holding the request thresholds + help notes is now titled **Officer** and its `hidden` function is `not CanViewOfficerNote()`, so only the GM and officers can see or change those settings (previously bankers could too). Location: `Modules/Options.lua`.
- **REQUI-002: Requests window top strip decluttered + real tab widget** — The top strip now holds only the tabs (`Requests | Archive | Settings`), and they are now an AceGUI `TabGroup` (the proper WoW tab-shaped tabs, matching FastGuildInvite) instead of red `UIPanelButton`s. The widget is used purely as a tab bar — its content box backdrop is removed so only the tab row shows; the request list and Settings panel still render below as separate window children. Tab selection drives `currentTab` via `OnGroupSelected`; the old `UpdateTabButtons` text-prefix highlighting was removed (the tab widget shows the active tab itself). Per-tab hover tooltips use `OnTabEnter`/`OnTabLeave`. The `Cancel Stale` button and the full-width `< Prev` / `Next >` pagination buttons no longer crowd the top. Location: `Modules/UI/Requests.lua`.
- **REQUI-003: Pagination and Cancel Stale moved to compact status-bar icons** — The `< Prev` / `Next >` buttons are now compact page-turn arrow icons (`UI-SpellbookIcon-PrevPage`/`NextPage`) next to the bottom-right help `?` icon, dimming automatically at the first/last page. The `Cancel Stale` action is now a small broom icon (`Interface\Icons\INV_Broom_01`, the Hallow's End Magic Broom texture) in the same cluster, shown only to officers/bankers. The status bar's right edge auto-shrinks to clear the icon cluster (wider when the broom is present). On the Settings tab these icons are hidden since they don't apply. Location: `Modules/UI/Requests.lua`.
- **REQUI-004: Settings panel compacted + tooltip cleanup** — The three numeric settings (Archive, Auto-cancel, Max request %) now sit on a single compact row instead of three stacked label+description blocks, freeing ~110px the cancel-reason list now uses. The redundant "Request Settings" title was removed (the tab already says Settings). Field descriptions now live on the **label's** hover tooltip rather than the edit box, so the tooltip no longer covers the field while typing. The cancel-reason `Mbr` / `Bnk` / `Reason` column headers and the "Custom Cancel Reasons" heading now have hover tooltips (the heading's how-to text was moved off-screen into its tooltip), via a new `attachLabelTooltip` helper that overlays a hit frame on a FontString. Location: `Modules/UI/Requests.lua`.
- **REQUI-006: Bottom status-bar row tidied** — The status bar now extends right to meet the icon cluster instead of stopping ~22px short, and every bottom-row icon (help `?`, `<` / `>` page arrows, broom, fulfill envelope) is the same size (22px) with equal 8px gaps. The cluster sits in the gap left of the AceGUI Close button (which occupies x -127..-27), with the help icon at -133 so it never overlaps Close. Rather than a hardcoded right-edge inset, the status bar's `BOTTOMRIGHT` is anchored 6px to the left of whichever icon is actually leftmost (`self.FulfillOldestBtn or self.CancelStaleBtn or prevPageBtn`), so the bar always meets the cluster with even spacing regardless of which icons a given user has — fixing the large gap that appeared when the old fixed offsets didn't match the real cluster width. Location: `Modules/UI/Requests.lua`.
- **REQUI-007: Clickable text column headers (no more red buttons)** — The request-table column headers were red `UIPanelButton`s whose centered text didn't line up with the data cells below. They are now plain `InteractiveLabel` sort headers — gold text with a hover glow, click to sort, sort arrow appended — each justified to match its column's data so headers and rows align. Mirrors the FastGuildInvite RowList header style. A per-column `headerAlign` override centers the `Item` header, and a `headerSuffix` (trailing space) nudges the right-justified `#` header in by one character so it sits over the first digit of the quantity rather than the `x`. `EnsureHeaderRows` builds `InteractiveLabel`s instead of `Button`s. Location: `Modules/UI/Requests.lua`.
- **REQUI-008: Tightened vertical spacing above the request list** — The tab strip's `TabGroup` height was trimmed (34 → 30) to close the gap between the tabs and the filter dropdowns, and the column-header row gained ~3px of breathing room above it (header group content `y` offset `0 → -3`). Location: `Modules/UI/Requests.lua`.
- **SEARCH-001: Armor equip-slot filter in the Search window** — When the Filter is set to `Type → Armor`, a new `Slot` dropdown (between the subtype and Sort dropdowns) lets you narrow results to a specific equip slot — Head, Shoulder, Chest, Wrist, Hands, Waist, Legs, Feet, Back, Neck, Finger, Trinket, Shield, Held In Off-hand, or Relic. It combines with the existing armor subclass (Cloth/Leather/Mail/Plate) filter, so e.g. `Plate + Legs` works. The dropdown is disabled for non-armor types. Items' equip slot is resolved on demand from `GetItemInfo` (#9) and cached on the item's `Info` table (`equipSlot`), so no change to the synced data schema; `INVTYPE_CHEST`/`INVTYPE_ROBE` collapse to one `Chest` entry, etc. New `SLOT_LIST`/`SLOT_ORDER`/`INVTYPE_TO_SLOT` tables, a `resolveSlotKey` helper, a `subSlotDropdown` widget + `resetSlot` cascade, `self.SubFilterSlot` matching in `SubFilterMatches`. Location: `Modules/UI/Search.lua`.

### Internal

- Pagination buttons are now raw `Button` frames (with normal/pushed/disabled/highlight textures) rather than AceGUI buttons; a file-local `setBtnEnabled` helper replaces the old `SetDisabled` calls at the two page-state update sites. The Settings overlay is a `BackdropTemplate` frame rebuilt per window; its references (`SettingsOverlay`, the three editboxes, `SettingsTabBtn`, and the cancel-reason editor widgets/row pool) are cleared in the window's reset block, and `CancelStaleBtn` is cleared before its conditional creation so a lost-banker-status window recreation doesn't read a stale reference. Location: `Modules/UI/Requests.lua`.
- **CANCELREASON-001 sync/storage:** `cancelReasons` is added to the `guild-settings` broadcast payload and validated on receive by a new `TOGBankClassic_Guild.SanitizeCancelReasons` helper (clamps to 20 custom reasons × 160 chars, coerces booleans, ignores a missing field so old clients don't wipe local state). Defaults and a migration block were added to both `Info.settings` init sites in `Modules/Database.lua`. The built-in flavor presets were extracted from the cancel dialog into a shared `buildPresetReasons(role)` builder (keyed so they can be individually disabled). A `strtrim` global was added to `.luarc.json`. Locations: `Modules/Guild.lua`, `Modules/Database.lua`, `Modules/UI/Requests.lua`, `Modules/Constants.lua` (SETTINGS tag description).

## [v1.1.1] (2026-05-29) - Sorting Fixes & Random-Suffix Request Variants

### Bug Fixes

- **SORT-001: "By Type" split same-material gear across equip slots** — The inventory "By Type" sort ordered items by item class → **equip slot** → subclass, so a player's cloth pieces were broken up by slot and interleaved with leather/mail (e.g. 6 cloth, 3 leather, then 1 more cloth) instead of grouping all cloth together. Reordered the comparator to class → **subclass/material** → required level (see SORT-003) → equip slot → rarity → name, so all cloth groups, then all leather, then all mail. Location: `Modules/Item.lua` `Sort` (`type` mode). The Search window had **no** `type` sort case at all (selecting "By Type" left results in scan order); added a matching comparator there. Location: `Modules/UI/Search.lua` `DrawContent` sort block.

- **SORT-002: "Level" sort and the Min/Max level filters used item level, not required level** — `Info.level` was populated from `GetItemInfo`'s item-level return (#4) but was treated everywhere as the *required-to-use* level — in the "Level (High/Low)" sort, the Search window's "Minimum/Maximum Required Level" filters, and the "usable by my level" filter. Because item level and required level diverge non-monotonically, the "High to Low" sort looked like it descended, jumped back up, and repeated rather than producing a clean ordering. Now captures the required-level return (#5) into a new `Info.reqLevel` field and uses it for the level sort and all three level filters. Required level is resolved from the live item cache (`GetItemInfo`), which is warm by the time items are on screen. Items that arrive with a pre-existing `Info` table — item data synced from other players or loaded from saved data predates the field — are resolved at sort time, retrying whenever `reqLevel` is unresolved (nil **or** 0) and only writing a positive result. This avoids the bug where a 0 written during a cold-cache window stuck permanently and broke the ordering. Locations: `Modules/Item.lua` (Info captures, `Sort` prep + level comparators, `GetItems` backfill, `GetInfo`), `Modules/UI/Search.lua` (sort-prep resolution, level comparators, `SubFilterMatches`).

- **REQ-003: Requests for random-suffix items matched the wrong variant** — Random-property gear such as "Spiked Club of the Tiger" and "Spiked Club of the Monkey" share a single base item ID and differ only by their random-suffix ID. Because a request stored only the numeric item ID, the requests screen tooltip and the mail fulfillment/availability checks matched the *first* item sharing that base ID — so a request for the Tiger variant showed (and would be fulfilled by) the Monkey variant. Requests now also capture the random-suffix ID and match on it: the tooltip resolves to the requested variant, and bag scanning / fulfillment only count the matching suffix. New optional `suffixID` field appended to the request record and the `togbank-rd2` wire format (slot 13, append-only); older clients and pre-existing requests have no suffix data and fall back to the previous item-ID matching, so there is no regression. New helper `TOGBankClassic_Item:GetSuffixID(link)`. Locations: `Modules/Item.lua`, `Modules/RequestLog.lua`, `Modules/UI/Search.lua` (request creation), `Modules/UI/Requests.lua` (tooltip), `Modules/Bank.lua` (`FindItemsByName`/`CountItemInBags`), `Modules/Mail.lua` (`CanFulfillRequest`/`PrepareFulfillMail`).

### Improvements

- **SORT-003: "By Type" now orders each material by level** — Within each material/subclass group, items are ordered by required-to-use level high→low (then equip slot, rarity, name as tie-breakers), so a type-sorted list reads cleanly within each group (all plate: 50, 49, 48…) instead of relying on slot/name alone. Applies to both the inventory and Search windows. Locations: `Modules/Item.lua` `Sort` (`type` mode), `Modules/UI/Search.lua` `DrawContent` sort block.

### Internal

- **`.luarc.json`** — Added `strsplit` to `diagnostics.globals` (used by the new `GetSuffixID` helper).

## [v1.1.0] (2026-05-23) - Data Corruption Fix: Linkless Gear Ghosts & Inflated Counts

### Bug Fixes

- **ITEM-004: `EnsureLegacyFields` was poisoning `alt.bank.items` with mail-item references** — When peer-relayed alt data arrived carrying only `alt.items` (the aggregated bank+bags+mail view) without the separate `bank/bags/mail` fields, `EnsureLegacyFields` "reconstructed" `alt.bank.items` by copying every entry from `alt.items` — including mail items. Subsequent re-aggregation in `ApplyDelta` then ran `Aggregate(bank, bags)` followed by `Aggregate(result, mail)`, summing mail items twice per delta application. Across many peer-relay cycles, gear item counts inflated monotonically — in real SavedVariables, "Battlefell Sabre of Power" (ID=15220) reached Count=6237 and base "Battlefell Sabre" reached Count=21 (both physically impossible for non-stacking weapons). Fix removes the copy loop entirely; the next direct delta from the actual banker repopulates `bank.items` cleanly. Location: `Modules/Guild.lua` `EnsureLegacyFields` (~line 2282). Root cause documented in `docs/DELTA_BUGS.md` ITEM-004.

- **ITEM-003 guard holes on `ApplyItemDelta` update/fallback paths** — The receive-side guard against linkless weapons/armor only fired on the new-insert paths. The ID-only fallback paths in both STEP 2 (modified) at line 904 and STEP 3 (added) at line 1010 silently mutated linkless gear ghost entries into suffixed entries via `for field, value in pairs(changes) do existingItem[field] = value end` and `existingItem.Count = newItem.Count`. This propagated whatever Count the inbound delta carried into a ghost that should never have existed, causing count divergence across replicas. Fix detects ID-only-fallback matches against linkless gear and DROPS the ghost before falling through to the clean-add path, where the existing ITEM-003 new-insert guard catches subsequent linkless gear payloads. Location: `Modules/DeltaComms.lua` `ApplyItemDelta` STEP 2 and STEP 3.

- **`NeedsLink` / `ItemClassNeedsLink` could strip gear links during cold-cache windows** — The fallback path in `NeedsLink` consulted the item's hyperlink suffix field when `GetItemInfo`'s class lookup returned nil (uncached). For base/no-suffix gear items the suffix is 0, so the fallback returned false and stripped the link, producing the linkless gear ghosts that ITEM-003 / ITEM-004 then propagated. Replaced both functions with a default-deny strip policy: a link is stripped ONLY when class can be positively confirmed as non-gear (class != 2 AND != 4). Uncached, unparseable, or unknown items now preserve the link. The "Weapons (class 2) and Armor (class 4) ALWAYS keep their Link" rule documented in the file finally actually holds. Location: `Modules/Item.lua` `NeedsLink`, `ItemClassNeedsLink`, plus new `Item:GetClass(itemID)` tiered-lookup helper.

### New Features

- **Generic tooltip helper `TOGBankClassic_UI:AttachTooltip(target, anchor, title, lines)`** — Single one-call API for non-item tooltips. Auto-detects AceGUI widget vs raw frame and wires `OnEnter`/`OnLeave` via the right API. Replaces the 5-line `GameTooltip:SetOwner` / `ClearLines` / `AddLine` / `Show` scriptlet pattern that was sprinkled across UI modules. New Search-window tooltips use it; existing call-sites kept as-is for now (gradual migration). Location: `Modules/UI.lua` (~line 230).

- **Search window: info "i" icon + Prev/Next at bottom-right** — Mirrors the inventory window's bottom-right layout. The "?" help icon explains how the Search window works (input field, filters, pagination). Pagination buttons moved from a full-width "< Previous / Next >" row to compact `<` / `>` icon-sized buttons next to the close button — saves ~30px of vertical space, freeing the result list. Status bar shrunk by ~210px to leave room. Both pagination buttons keep the existing `:SetDisabled(bool)` API so `DrawContent`'s page-state logic works unchanged. Location: `Modules/UI/Search.lua` bottom-right control row.

- **Search window: tooltips on Min lvl / Max lvl / Usable** — All three filter controls now have explanatory hover tooltips wired via the new `AttachTooltip` helper. Min/Max explain that empty/0 means "no constraint" and that items without a level are hidden when a min is set. Usable explains the gating (disabled until a Type/Quality is picked).

- **Search window: Sort tooltip moved from dropdown control to label** — Previously the Sort tooltip fired when hovering the dropdown itself, which competed with the click-to-open-dropdown gesture (popped up while the user was trying to click). Now it lives on a hit frame over the "Sort" label, matching the Filter dropdown's pattern.

- **Search window: filter row reordered (Min lvl, Max lvl, then the rest)** — The numeric inputs now lead the row so the small controls cluster densely in the top-left and don't get orphaned on their own row when the window is narrow.

- **Search window: Min/Max EditBox labels repositioned** — Labels shifted 5px right (+5, -2) so they no longer overhang the EditBox's left edge.

- **Min/Max level filter in the Search window** — Two new compact numeric inputs (`Min lvl` and `Max lvl`, 60px each) let players filter results by the item's required level. Empty or non-numeric input is treated as "no constraint" so partial ranges work (just a min, just a max, or both). Cheap to compute → no gating on other filters being set first. Combines with the existing Type/Quality/Usable filters. Location: `Modules/UI/Search.lua` `SubFilterMatches` and filter section.

- **Compact, auto-wrapping filter row in the Search window** — The filters used to be four full-width-stacked dropdowns plus an inline checkbox glued to the Filter dropdown's right edge — five tall rows that ate half the window before the results even started. They're now a single Flow-laid-out row with each control sized to its content (Filter 110px, Subtype 130, Sub-subtype 130, Sort 150, Min lvl 60, Max lvl 60, Usable 80 — total ~720px). On a wide search window everything fits on one row; resize the window narrower and they wrap onto multiple rows automatically. The "Usable by my level" checkbox is now a standalone AceGUI CheckBox (previously a raw CheckButton anchored to the Filter dropdown's frame), so it participates in the wrap layout instead of forcing the Filter dropdown to stay 165px wider than it needs to be. Location: `Modules/UI/Search.lua` filter section.

- **Settings gear icon on the main inventory window** — A new ⚙ button sits next to the existing help "?" icon at the bottom-right of the inventory window. Clicking it opens the TOGBankClassic options panel directly (equivalent to Escape → Options → AddOns → TOGBankClassic), so players don't have to navigate through the game menu to change banker/scan configuration, minimap button, debug settings, etc. Hover for a tooltip. Location: `Modules/UI/Inventory.lua` (~line 144).

- **One-shot ghost-purge migration on `Database:Init`** — Scheduled 30 seconds after addon init (gives WoW's item cache time to warm). Walks every alt's `items`, `bank.items`, `bags.items`, and `mail.items` arrays; drops entries that have no `Link` field AND are confirmed by `ItemClassNeedsLink` to be class 2/4 gear. Recovers existing corruption in SavedVariables without requiring `/togbank wipe`. Always prints a result line so users know it ran (purged count + skipped-suspect count, even when zero). Can be manually re-run via `/togbank dev purgeghosts`. Location: `Modules/Database.lua` `PurgeLinklessGearGhosts`.

- **Static item DB populated from wago.tools (`Modules/Static/ItemDB.lua` + `SuffixDB.lua`)** — Ships with ~24,000 item entries (every item in Classic Era 1.15.8) and ~2,000 random-suffix fragments. `NeedsLink` / `ItemClassNeedsLink` consult `TOGBankClassic_ItemDB` first via a tiered lookup (static DB → `GetItemInfo` → default-deny), so strip decisions no longer depend on the volatile WoW client cache. Regenerated by `tools/build-itemdb.py` which pulls Blizzard's actual DB2 dumps (ItemSparse + Item + ItemRandomProperties + ItemRandomSuffix). Wire schema unchanged in this release; bandwidth-reduction changes (Phase 3) will land in a follow-up release.

- **`tools/build-itemdb.py` — wago.tools fetch + Lua generator** — Python script (no third-party deps, Python 3.9+) that fetches DB2 tables from wago.tools, joins, filters suffix junk (rejects fragments not starting with "of "), and emits `Modules/Static/{ItemDB,SuffixDB}.lua`. Caches downloaded CSVs under `tools/wago_cache/` (gitignored). Re-run when a new Classic patch ships new items. Pattern modelled on TOGProfessionMaster's `tools/wago_probe.py`. Excluded from packaged builds (`.pkgmeta` `tools/` entry).

- **Developer-only command namespace `/togbank dev <subcommand>`** — Twenty-two dev/debug commands previously listed in `/togbank help` (clearhistory, clearsnapshots, deltaerrors, deltahistory, deltastats, forcedelta, forcefull, perfstats, persistcheck, protocol, resetmetrics, test, versioncheck, hashupdate, hashdebug, hashdump, netq, reqscan, debugdump, debuglogsave, clear-delta-errors, plus the new purgeghosts) are now hidden from the user-facing help output and dispatched only via the `dev` namespace. `/togbank dev help` lists them for developers. Reduces the top-level command list from ~30 to ~11 entries. New `DEV_COMMAND_NAMES` lookup in `Modules/Chat.lua` controls which commands route through the dev dispatcher — flipping a command between user-facing and dev-only is a one-line change. Full catalogue and developer workflows documented in `docs/DEV_COMMANDS.md` (not packaged to users — `docs/` is ignored in `.pkgmeta`).

- **`/togbank dev purgeghosts` — manual ghost-purge trigger** — Re-runs the linkless-gear-ghost migration on demand. With the populated static `TOGBankClassic_ItemDB` shipping in this release, the purge can confidently classify almost any item without relying on the WoW client's session cache. Location: `Modules/Chat.lua` COMMAND_REGISTRY.

### Internal

- **Removed obsolete local-build pipeline** — Deleted `package.bat` (referenced a no-longer-existing `embeds.xml` and would have errored on run) and the stale `dist/` directory (contained one orphan `TOGBankClassic.@project-version@.zip` from before the move to the BigWigs CurseForge packager). All release builds now flow exclusively through `.pkgmeta` + the CurseForge auto-builder. Defensive `**/*.bat` ignore pattern kept in `.pkgmeta` to catch any future leftover scripts.

- **Removed dead `function s(a)` at `Guild.lua:3030`** — Generic table-entry counter, defined as a global (lowercase), never called from anywhere in the codebase. Eliminating it removes one `lowercase-global` warning and two `unused-local` hints (`c`, `d` loop variables).

- **CLAUDE.md updated** — Replaced the references to `package.bat`/`dist/` (now gone) with notes on the current packaging pipeline. The "scratch files use `tmpclaude-` prefix" rule is preserved but no longer mentions the obsolete robocopy exclusion.

- **Documentation cleanup** — Removed duplicate `docs/CHANGELOG.md` (the canonical changelog has always been the repo-root `CHANGELOG.md`). Updated `.pkgmeta` ignore list: `docs/` directory now fully excluded from packaged builds (was: `*.md` only), `CLAUDE.md` explicitly excluded, `*.md` no longer blanket-ignored so root-level `CHANGELOG.md` ships to CurseForge as intended.

- **README.txt cleanup** — Removed dev commands from the EXPERT COMMANDS section. Rewrote MONITORING DELTA SYNC and two TROUBLESHOOTING entries to direct players at debug logging instead of dev-only counters. Kept genuinely user-facing expert commands: `compact`, `debuglog`/`debuglogclear`/`debuglogstats`/`debugtab`/`debugtabremove`, `roster`, `wipe`, `wipeall`, `wipeframes`, `debug`.

- **`Tests.lua` lint fixes** — Suppressed two `duplicate-set-field` warnings on the mocked `Database.GetGuildDeltaSupport` reassignments using the established `---@diagnostic disable-next-line` pattern.

- **Minor lint cleanup in `Chat.lua`** — Removed an unused vararg and an unused loop-variable name in `ProcessQueue` and `PrintDeltaHistory` respectively (encountered while editing the dispatcher).

- **`.luarc.json` global registration** — Added `TOGBankClassic_ItemDB`, `TOGBankClassic_SuffixDB` to `diagnostics.globals`.

- **TOC additions** — new `Modules/Static/ItemDB.lua` and `Modules/Static/SuffixDB.lua` load entries (loaded early so anything that queries item class has them available).

### Developer / Sync architecture follow-ups (planned, not in this release)

- Bump `PROTOCOL.VERSION` to 3 once the static DB is populated and committed.
- Peer-aware `StripDeltaLinks`: emit minimal `{ID, Count, suffixID?, randomProperty?}` payload to peers known to support the static DB; continue sending legacy `{ID, Count, Link/ItemString}` to old peers. Backwards-compatible per Option A in the design discussion.
- Update `ApplyItemDelta` and `ReceiveAltData` to reconstruct items from minimal payloads using `TOGBankClassic_ItemDB` and `TOGBankClassic_SuffixDB`.
- Expected wire bandwidth reduction: 4-5x for non-gear items, 5-7x for random-suffix gear, 8-10x for fixed-roll gear once everyone is on the new protocol.

---

## [v1.0.0] (2026-04-11) - First Stable Release: Fulfill Location Awareness & Polish

### New Features

- **Fulfill button location awareness** — The fulfill button now shows distinct icons and contextual tooltips for three new states, making it clear why an item cannot be mailed immediately and where to find it:
  - *Item in mail inbox* — wax letter icon (`INV_Letter_06`); tooltip: "Item is in your mail inbox. Retrieve it first, then fulfill the order."
  - *Item split across bank and mail* — paired bag + letter icons; tooltip: "Item is split between your mail inbox and bank. Retrieve mail items first, then pick up the rest from the bank."
  - *Shortage — more available in bank/mail* — contextual icon matching the location; tooltip shows exact current bag count and target quantity (e.g. "Have 125 in bags. More available in your bank and mail inbox — pick up or retrieve the rest to reach 150."). Three sub-states: bank only, mail only, or both.

### Bug Fixes

- **TOOLTIP-001: Item link tooltips showed banker data for ex-guild members** — The `OnTooltipSetItem` hook in `TooltipBankerInfo.lua` iterated all database entries with no guild membership check, surfacing data from characters who had left the guild. Fixed by adding an `IsInCurrentGuildRoster()` check as a combined guard — only alts currently in `memberRoster` (O(1) lookup) are shown. Location: `Modules/TooltipBankerInfo.lua`.

- **FULFILL-001: Fulfill button icon stuck on shovel after a bag split** — After splitting a stack to fulfill an order, the bag-update event called `DrawRows()`, which skips non-dirty rows. The row was already drawn so `DrawRows()` was a no-op and the split icon never transitioned. Fixed by replacing the `DrawRows()` call in `OnBagUpdate` with `_RefreshFulfillButtons()`, which re-evaluates all visible rows regardless of dirty state. Location: `Modules/UI/Requests.lua`.

- **FULFILL-003: "Item in bank and mail" showed a blank red button** — The combined icon used `INV_Misc_Chest_01`, which does not exist in Classic Era; the engine renders a blank red placeholder for any missing texture. Fixed by replacing it with two confirmed-working icons rendered side-by-side at 14px: `INV_Misc_Bag_07` (bag) and `INV_Letter_06` (wax letter). Location: `Modules/UI/Requests.lua`.

- **HIGHLIGHT-001: Bagnon bag highlighting broken for recipe and pattern items** — `UpdateBagnonHighlighting` inserted raw item names into the Bagnon search string. Tradeskill items whose names include a colon prefix (`Pattern: Ironfeather Breastplate`, `Formula: Enchant Weapon`, etc.) caused Bagnon's search parser to silently discard the entire term. Fixed with a shared `stripRecipePrefix` helper that strips all known Blizzard craft prefixes before appending to the search string. Location: `Modules/ItemHighlight.lua`.

---

## [v0.10.10] (2026-04-04) - Same-Name Item Variant Disambiguation

### Bug Fixes

- **REQ-001: Same-name item variants were indistinguishable in the request system** — All class-specific Punctured Voodoo Doll variants (Priest, Warrior, Druid, etc.) share an identical display name from `GetItemInfo`, but each has a unique numeric item ID. The request system stored only `request.item` (the name string), so every subsystem — bag scanning, mail fulfillment detection, item highlighting, and `CheckMailFulfillment` — matched solely by name and treated all class variants as identical. A banker holding only a Warrior doll would appear able to fulfill a Priest request, wrong bag slots were highlighted, and mail detection credited the wrong variant. Fixed by threading `request.itemID` (numeric Blizzard item ID) through the entire request lifecycle with full backward compatibility: old clients that never set `itemID` automatically fall back to name-based matching everywhere. Location: `Modules/RequestLog.lua`, `Modules/UI/Search.lua`, `Modules/Bank.lua`, `Modules/Mail.lua`, `Modules/ItemHighlight.lua`.

- **REQ-002: Requests UI item tooltip showed wrong same-name variant** — The `OnEnter` handler on each item row searched guild inventory by display name and took the first match, so hovering a Druid doll request always showed whichever class variant `pairs()` iterated first (typically Warrior). Fixed by storing `request.itemID` on the EditBox frame and using it for exact ID matching in the tooltip lookup; falls back to name search for legacy requests. Location: `Modules/UI/Requests.lua`.

- **ItemHighlight lint errors** — Five `undefined-field` warnings on `RegisterEvent` and `SetScript` calls after `CreateFrame` were suppressed with `---@diagnostic disable-next-line` comments, matching the established pattern in `Modules/UI/Requests.lua`. Location: `Modules/ItemHighlight.lua`.

### Internal

- **Pre-existing bug fixed (ItemHighlight)** — `BuildNeededItemsList` computed needed quantity as `request.quantity - request.quantityFulfilled`, but the schema field is `request.fulfilled` (`quantityFulfilled` never existed). The needed-quantity calculation therefore never subtracted already-fulfilled amounts. Fixed to use `request.fulfilled`. Location: `Modules/ItemHighlight.lua`.

---

## [v0.10.9] (2026-04-03) - Cancel Reason Overhaul, Fulfillment Sound Fix & Options Cleanup

### New Features

- **Role-aware cancel reasons** — The cancel request dialog now shows different reason lists depending on who is cancelling. Bankers see six flavour-text reasons (item unavailable, policy % limit, wrong banker, already claimed by an earlier requester, duplicate request, requester not in guild). Non-bankers cancelling their own orders see five separate reasons (changed mind, found on AH, already received elsewhere, wrong item/mistake, plans changed). Role is determined at dialog open time via `TOGBankClassic_Guild:IsBank(actor)`. Location: `Modules/UI/Requests.lua`.

- **Order fulfillment sound toggle** — New Options toggle "Play Sound on Order Fulfilled" (Options → TOGBankClassic, defaults on) lets players disable the mail-arrival sound without losing the chat notification. Location: `Modules/Options.lua`, `Modules/Mail.lua`.

### Bug Fixes

- **MAIL-014: Order fulfillment sound never played** — `PlaySound("AuctionWindowClose")` used a string-based sound name removed from the WoW API in Patch 7.3.0. Classic Era requires a numeric SoundKitID. Fixed by replacing with `SOUNDKIT.AUCTION_WINDOW_CLOSE` (with numeric fallback `11561`). Location: `Modules/Mail.lua`.

- **Tooltip bleed on Reset Database button** — The "Communication Protocol" description widget (now removed) was leaking its stale AceGUI Label text into the Reset Database button tooltip. Resolved by removing the widget entirely.

### Improvements

- **Reset Database button tooltip** — The Reset Database button in Options now has a proper `desc` tooltip explaining what it does, that it is irreversible, and that it is equivalent to `/togbank wipe`. Location: `Modules/Options.lua`.

### Internal

- **Removed Communication Protocol dropdown** — The "Communication Protocol" select dropdown (AUTO / Legacy Only / New Only) was dead UI — `FEATURES.PROTOCOL_MODE` was set by the dropdown but never read by any send or receive code path. Removed the dropdown, its description widget, the `PROTOCOL_MODES` constant table, the `PROTOCOL_MODE` field from `FEATURES`, the `protocolMode` SavedVariables default, and its nil-check initialiser. Location: `Modules/Options.lua`, `Modules/Constants.lua`.

---

## [v0.10.8] (2026-04-02) - Requests UI Pagination & Copyable Item Text

### New Features

- **Requests UI pagination** — The Requests window now shows 50 rows per page with Previous/Next navigation buttons and a page status display ("Showing 1–50 of 127 (Page 1/3)"). Eliminates game freezes when switching from a specific banker filter to "Any Banker" with 100+ requests. Follows the same pattern as the existing Search UI pagination. Location: `Modules/UI/Requests.lua`.

- **Copyable item text in Requests window** — Item name cells in the Requests window now have a transparent EditBox overlay. Click an item name to highlight the text, then Ctrl+C to copy it. Typing is blocked (original text is restored); Escape clears focus. Item coloring by status (red/cancelled, green/fulfilled, white/open) continues to render via the Label underneath. Location: `Modules/UI/Requests.lua`.

- **Item link tooltip on hover** — Hovering any item name in the Requests window shows the full WoW item tooltip (stats, quality, level requirements). Uses `SetHyperlink` with the stored item link from guild inventory; falls back to `item:ID` if no link is cached. Anchors to the right of the item name row. Location: `Modules/UI/Requests.lua`.

### Improvements

- **"Requests synced." confirmation message** — A brief chat confirmation is now printed when a user-triggered `/togbank sync` completes, consistent with other command responses. Location: `Modules/Chat.lua`.

---

## [v0.10.7] (2026-04-02) - P2P Delivery Watchdog Tuning

### Bug Fixes

- **P2P-032: Delivery watchdog shorter than AceCommQueue drain time** — The `OnSyncAccept` delivery watchdog fired after 60 seconds, which is shorter than the observed 68–70 second worst-case drain time for a 9 KB payload through AceCommQueue under load. This caused premature `OnFailed` calls, unnecessary catch-up cycles, and the add-on repeating sync work that was already in flight. Fix: raised `DELIVERY_TIMEOUT` to 180s and `SEND_TIMEOUT` to 210s to comfortably exceed observed worst-case drain times. Location: `Modules/P2PSession.lua`.

---

## [v0.10.6] (2026-04-01) - Send Cap Unification & Cross-Guild Guard

### Bug Fixes

- **P2P-031: Pull-based responder bypassed P2P send-slot cap** — The legacy `togbank-r` alt-request responder and the new `HandleSyncRequest` P2P responder maintained completely independent counters (`pendingSendCount` vs `P2P.activeSends`), allowing up to 6+ simultaneous outbound data streams. Observed symptom: 20–30 concurrent "Sharing guild bank data…" messages, with some taking 60–150 seconds. Fix: extracted `TryAcquireSendSlot` / `ReleaseSendSlot` helpers into `P2PSession.lua`; both paths now compete for the single shared 3-slot cap in `P2P.activeSends`. Location: `Modules/P2PSession.lua`, `Modules/Guild.lua`, `Modules/Chat.lua`.

- **ROSTER-004: Cross-guild alts polluting banker hash list** — `latestBankerHashes` accumulated entries for alts from other guilds or ex-bankers whose roster entries were stale in SavedVariables. The `togbank-hlr` handler accepted any alt name without validating `IsBank()`. Fix: (A) `BuildBankerHashList` now prefers the live `GetBanks()` cache over the persisted roster alts. (B) All three write paths in the `togbank-hlr` handler now guard on `IsBank(norm)` before writing. Location: `Modules/Guild.lua`, `Modules/Chat.lua`.

- **SEND-001: Send progress always showed "1 chunks, 0.0s"** — The chunk callback fired only once (at completion, not per chunk), so `startTime` was captured and read in the same frame, and `chunksSent` was always 1. Fix: capture `startTime` at closure creation; show estimated chunk count via `math.ceil(totalBytes / 254)`; move the progress message to fire at send *start* rather than completion. Location: `Modules/Guild.lua`.

---

## [v0.10.5] (2026-04-01) - Slash Command Aliases, CRC Recovery & Dead Code Removal

### New Features

- **`/bank` and `/gbank` slash command aliases** — Two new configurable aliases toggle the main inventory window. Each alias can be individually enabled or disabled in Options → TOGBankClassic → Commands. The `/bank` shortcut is enabled by default; `/gbank` disabled by default (in case another addon uses it). Location: `Modules/Chat.lua`, `Modules/Options.lua`.

### Bug Fixes

- **REQSYNC-009: Silent data loss on `togbank-ri` CRC mismatch** — When a request index chunk arrived with a valid stop-marker but a failed CRC (genuine bit corruption), the receiver logged the error and returned with no further action — leaving a permanent blind spot for the affected request IDs until the next sync cycle. Fix: added a recovery branch immediately after the INTEGRITY-MISMATCH log that re-requests the full index from that sender with `force=true` to bypass the per-sender cooldown. Location: `Modules/Chat.lua`.

- **ALIAS-001: Duplicate `/bank` registration in `Init()`** — A hardcoded `RegisterChatCommand("bank", ...)` in `Chat:Init()` predated the new alias system and overrode it on some load orderings. Removed; `/bank` is now exclusively owned by `RegisterAliasCommands()`. Location: `Modules/Chat.lua`.

### Internal

- **MAINT-001: Dead code removal campaign** — ~350 lines of unreachable code removed across 9 files, including: delta history cluster (`SaveDeltaHistory`, `GetDeltaHistory`, `CleanupDeltaHistory` + all call sites), `SanitizeDelta`, `SanitizeItemDelta`, `GetPeerCapabilities`, `MarkPlayerSeen`, orphaned Constants fields (`DELTA_HISTORY_*`, `DELTA_CHAIN_*`, `sendLegacy`/`sendNew`), dead `ItemHighlight` constants, and an unreachable two-header layout branch in `UI/Requests.lua`. Location: `Modules/Database.lua`, `Modules/Events.lua`, `Modules/Chat.lua`, `Modules/DeltaComms.lua`, `Modules/Guild.lua`, `Modules/Constants.lua`, `Modules/ItemHighlight.lua`, `Modules/UI/Requests.lua`.

---

## [v0.10.4] (2026-03-31) - AceCommQueue-1.0 Send Queue Library

### New Features

- **AceCommQueue-1.0 embedded library** — A new transparent send-queue library (`Libs/AceCommQueue-1.0/`) sits on top of AceComm-3.0 and prevents multipart message chunk interleaving on the wire. When two messages share the same prefix, AceComm's spool for that prefix is keyed on `prefix + sender`; a second `FIRST` chunk arriving mid-stream overwrites the partial assembly and causes CRC failures. AceCommQueue queues per `(prefix, distribution, target)` and only submits the next message after CTL confirms the last chunk of the current message was handed off. Priority ordering (`ALERT > NORMAL > BULK`) is preserved between messages. The library is fully transparent — existing `self:SendCommMessage(...)` call sites are unchanged. Includes debug output (`/acq on/off/status`) and LibStub versioning for future standalone distribution. Location: `Libs/AceCommQueue-1.0/AceCommQueue-1.0.lua`, `Core.lua`, `TOGBankClassic.toc`.

---

## [v0.10.3] (2026-03-30) - Cancel Reasons, Request Timeline Tooltips & P2P Stability

### New Features

- **Cancel reason dialog** — Cancelling a request now opens a dialog to select a reason before confirming. Three preset reasons are available, including one that dynamically reflects the current officer-configured request limit percentage. Location: `Modules/UI/Requests.lua`, `Modules/RequestLog.lua`.

- **Request timeline tooltip** — Hovering any row's date in the Requests window shows a "Request Timeline" tooltip with the submission timestamp, and (where applicable) the fill or cancellation timestamp. Cancelled rows also show the selected cancellation reason. Filled/completed rows include a note that mailed items take approximately 1 hour to arrive. Location: `Modules/UI/Requests.lua`.

### Improvements

- **Help tooltip updated** — The `?` icon on the Requests window now documents the date column mouseover tooltip and the cancel reason dialog. The obsolete "Delete" section has been removed. Location: `Modules/UI/Requests.lua`.

### Bug Fixes

- **P2P-030: Hash-list broadcast collision guard** — The `hashBroadcastInProgress` flag was previously cleared on a fixed 15-second timer. Under ChatThrottleLib congestion the drain could exceed 15 seconds, allowing a second broadcast to begin before the first finished draining, producing `INTEGRITY-MISMATCH` (`stop=PASS crc=FAIL`) errors on recipients. Fix: flag is now cleared via the AceComm `callbackFn`, which fires when ChatThrottleLib has finished queuing the last chunk — not on a timer guess. Location: `Modules/Events.lua`, `Modules/Guild.lua`.

---

## [v0.10.2] (2026-03-29) - Banker Tooltip Integration

### New Features

- **Item tooltip banker info** — Mousing over any item in-game now appends a "TOGBankClassic" section to the game tooltip listing every banker that stocks that item and their total quantity. Bankers are sorted by quantity descending, then alphabetically. Realm suffix is stripped for clean display. Location: `Modules/TooltipBankerInfo.lua`, `Core.lua`, `TOGBankClassic.toc`.

---

## [v0.10.1] (2026-03-29) - P2P Hash Reform & Integrity Diagnostics

### New Features

- **HASH-REFORM: P2P collect/offer as sole hash path** — The periodic hash sync now runs exclusively through the P2P collect/offer/dispatch pipeline. Fast-fill is suppressed during the collect window to prevent premature dispatch before all peers have responded. `/togbank hashdebug` now also reports alts with missing content. Location: `Modules/Events.lua`, `Modules/P2PSession.lua`, `Modules/Chat.lua`.

### Bug Fixes

- **P2P-023: Hash-list broadcast collision prevention** — Concurrent hash-list broadcasts on `togbank-hl` collided in the AceComm multipart spool (same spool key = second FIRST chunk overwrites partial data from the first, producing `CRC fail`). Fix: a `hashBroadcastInProgress` guard flag blocks new BULK broadcasts while one is in flight, and defers NORMAL/ALERT broadcasts with up to 3 retries (16s apart) before forcing through. Location: `Modules/Events.lua`.

- **P2P-REFORM: Dual-sync removed, first-run fixed, activeSessions cap corrected** — Removed a redundant second sync path that fired alongside the primary collect/offer cycle. Fixed a first-run edge case where no session was started. Corrected the `activeSessions` counter cap that could prevent new sessions from opening after prior ones closed. Location: `Modules/P2PSession.lua`.

### Internal

- **AceSerializer error captured in PAYLOAD-TYPE log line** — When a corrupt payload cannot be deserialized, the error string (e.g. `"Invalid serialized number: '136ation-Azuresong'"`) is now emitted alongside the `PAYLOAD-TYPE` diagnostic, making the exact splice point visible in the debug log. Location: `Core.lua`.

---

## [v0.10.0] (2026-03-28) - Sort Dropdowns, UI Consistency & Search Enhancements

### New Features

- **Sort dropdown in Search and Inventory windows** — Click the sort button to open a visual dropdown menu with 6-7 sort modes depending on the window:
  - **Search:** A-Z, By Type (armor/weapons/consumables/trade goods/etc.), By Rarity (epic→common), By Level (highest first), By Bank (groups by banker name), By Quantity (highest first)
  - **Inventory:** A-Z, By Type, By Rarity, By Level, By Slot (bags-1 through bags-5 then bank-1 through bank-7), By Quantity
  - Dropdown has collapsible "Sort Mode" and "Sort Options" sections with colored separators and bold headers
  - "Reverse" checkbox toggles ascending/descending sort order
  - Replaces old single-line button that cycled through modes directly
  - Location: `Modules/UI/Search.lua`, `Modules/UI/Inventory.lua`

- **Banker name shown in search results** — The Search window item list now displays the banker character name for each item, making it easier to identify which bank alt has what you're looking for. (UI-013) Location: `Modules/UI/Search.lua`.

- **Window sizes persist across reloads** — All three windows (Inventory, Search, Requests) now remember their dimensions between sessions via SavedVariables. (UI-014) Location: `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.

### Improvements

- **Thin 8px scrollbars across all windows** — Search, Inventory, and Requests windows now use narrow 8px scrollbars with the `UI-SliderBar-Button-Vertical` texture (matches dropdown pullout menu style), replacing the previous 16px default. Scrollbars positioned at right edge with 20px top/bottom padding to avoid overlapping adjacent buttons. Classic Era compatible (no SetBackdrop calls). Location: `Modules/UI/Search.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Requests.lua`.

- **Sort dropdown visual alignment** — In the Inventory window, the sort dropdown frame is anchored to the Inventory window's frame edges rather than the parent group, ensuring the dropdown pullout aligns perfectly with the window border. Location: `Modules/UI/Inventory.lua`.

- **Bolder dropdown section headers and separators** — Requests window dropdowns (requester/banker filters) now use bold colored headers and thicker colored separators for better visual hierarchy. Location: `Modules/UI/Requests.lua`.

- **"Rebuild Availability" button removed** — The button was a temporary workaround for a now-fixed duplicate stack counting bug and created confusion. Availability recalculates automatically on every bank scan. Location: `Modules/UI/Search.lua`.

### Bug Fixes

- **Requests dropdown closes immediately when clicked** — Clicking a dropdown in the Requests window was instantly triggering the Frame's OnClose callback (from the mouse-down event), immediately closing the dropdown pullout before the user could select an option. Fix: the dropdowns now set `dialog = true` to prevent AceGUI Frame from treating clicks as "click outside to close" events. (DROPDOWN-001) Location: `Modules/UI/Requests.lua`.

- **Sort by Type equipment slot grouping fixed** — Gear was not grouping properly by equip slot due to two issues: (1) Uncached items with `nil` class/subclass/equipSlot were falling into a catch-all "Other" bucket, and (2) equip slots were not being compared as a primary key ahead of the subclass tiebreaker. Fix: added async item cache loading so all item metadata is available before sorting; restructured comparator to order by equip slot first (1H/2H/head/chest/etc.), then class+subclass within each slot. (SORT-001, SORT-002) Location: `Modules/Item.lua`.

- **Debug frame un-docks General chat tab** — When closing the debug frame (`Alt+D` toggle), the General tab was unintentionally remaining selected as the active chat tab instead of restoring the tab the user was previously viewing. Fix: stores the active tab on frame open and restores it on close. (UI-012) Location: `Modules/Options.lua`.

### Internal

- **Enhanced INTEGRITY-MISMATCH diagnostics** — Stop-marker check now logs which debug category/tag would have been assigned to the corrupt message (e.g., `SEARCH/SERIAL`, `COMMS/HASH-LIST`), helping diagnose the source of truncation/corruption events.

---

## [v0.9.17] (2026-03-26) - Requests Archive, UI Tooltips & Integrity Diagnostics

### New Features

- **Requests Archive tab** — A second "Archive" tab in the Requests window shows requests older than the configured threshold (default: 30 days), keeping the main tab focused on active/recent requests. Location: `Modules/UI/Requests.lua`.

- **Configurable archive threshold** — Days-before-archive is user-configurable via **Options → Requests → Archive Threshold (days)**. Validated, persisted per-user to SavedVariables. Location: `Modules/Options.lua`, `Modules/UI/Requests.lua`.

- **Auto-tombstone for stale open requests** — Open requests older than the threshold are automatically rejected and tombstoned on receipt, preventing indefinitely-re-syncing requests from long-offline players. Fires on every sync path via `mergeRequest()` (REQUEST-RETIRE-003). Location: `Modules/RequestLog.lua`.

- **Guild-synced `autoTombstoneDays`** — The stale-request cutoff is officer-configurable via **Options → Requests → Auto-cancel threshold (days)**, written to `Guild.Info.settings.autoTombstoneDays` and broadcast to all clients. Location: `Modules/Options.lua`, `Modules/Database.lua`.

- **"Cancel Stale" bulk-tombstone button** — Officers and bankers get a "Cancel Stale" button in the Requests tab strip. Confirmation dialog shows how many requests will be cancelled; on confirm, tombstones all matching open requests and broadcasts `delete` mutations guild-wide. Location: `Modules/UI/Requests.lua`, `Modules/RequestLog.lua`.

- **Help icons and tooltips across all windows** — `?` icons on the Inventory and Requests windows; descriptive tooltips on all buttons, tab buttons, column headers, filter dropdowns, the highlight checkbox, and the Search label. Location: `Modules/UI/Inventory.lua`, `Modules/UI/Requests.lua`, `Modules/UI/Search.lua`.

### Improvements

- **Unified thin border** — Inventory, Requests, and Search windows now use the thin tooltip-style border (`UI-Tooltip-Border`, edgeSize=16) via a shared `ApplyThinBorder()` helper. Location: `Modules/UI.lua` and each window file.

- **Requests button row alignment** — Tab-strip buttons now sit at the same vertical baseline as the Inventory top-bar buttons. Location: `Modules/UI/Requests.lua`.

- **Custom minimap button icon.** (v0.9.16)

### Bug Fixes

- **Guild settings not broadcast to all members** — Officer-configured settings (max request %, auto-cancel days) were not reliably reaching all online members. Fix: settings are now broadcast at ALERT priority immediately on change. (SETTINGS-001) Location: `Modules/Guild.lua`.

- **No-change whispers missing slot counts** — Slot counts were omitted from no-change whispers, causing the receiver to incorrectly skip a needed sync in some cases. (SLOTS-002) Location: `Modules/Guild.lua`.

### Internal / For Testers

- **Stop-marker integrity diagnostic** — A `\031END` stop-marker is now appended to every outgoing message. On receive, it is checked (O(4)) in parallel with the existing O(N) CRC. If the stop-marker is present but CRC fails — indicating genuine bit-corruption rather than truncation — a debug log entry is written. A new opt-in toggle in **Options → Debug → Show Integrity Mismatch Alerts** (off by default) also prints a visible chat error, allowing designated testers to monitor for non-truncation corruption and determine whether the cheaper stop-marker check can eventually replace the full CRC. Location: `Core.lua`, `Modules/Options.lua`.

---

## [v0.9.15] (2026-03-24) - Critical Sync Fixes & Performance Overhaul

**Status:** Production Ready

### Bug Fixes

- **Banker broadcast marked `isBanker=false` on every 10-minute sync cycle** — `Guild:Share()` sent a preliminary `hash-list-broadcast` for just the local banker alt before calling `SyncDeltaVersion()`. This preliminary payload had no `isBanker` field; receivers read `data.isBanker or false` → `false` and treated the banker as a regular peer, skipping the `latestBankerHashes` cache update and the HLR dispatch. `SyncDeltaVersion()` then arrived with the correct `isBanker=true` and all 36 alts, but the 0.15s batch dedup window sometimes processed the bad message independently, leaving peers in a broken state and causing them to whisper hash-offers back to the banker (up to 50 members × 36 alts per cycle). The preliminary single-alt broadcast was also entirely redundant — `SyncDeltaVersion()` already includes the banker's own alt. Fix: removed the pre-broadcast from `Guild:Share()` entirely. (P2P-021)

- **`/togbank hashupdate` broadcast also missing `isBanker` field** — Same root cause as P2P-021 in a separate code path: `Guild:HashUpdate()` sent `hash-list-broadcast` without an `isBanker` field. Receivers processed it as a non-banker broadcast — `latestBankerHashes` was not updated and no HLR dispatch fired. Fix: added `isBanker = true` to the payload. (P2P-022)

### Performance

- **Guild roster lookups replaced with O(1) cache** — Several functions that ran on every incoming comm message were doing live full-roster scans instead of using the existing `memberRoster` table: `IsInCurrentGuildRoster()` (500-member loop + 1,500 `string.gsub` calls per message), `IsBank()` (iterated `banksCache` with `NormalizeName` on each entry), `GetBanks()` (re-scanned all members via `GetGuildRosterInfo()` whenever `banksCache` was nil), `SenderIsGM()`, `GetPlayerInfo()`, and the `QueryAltPullBased()` fallback path. Additionally, all banker detection in `GetBanks()`, `SenderHasGbankNote()`, and `RebuildBankerRoster()` used a `(.*)gbank(.*)` greedy regex that backtracks on every guild note. With 50 members online and all syncing near the 10-minute broadcast cycle these scans fired dozens of times per second, causing visible frame stutters. Fix: added `isBank` flag to each `memberRoster` entry (set using plain-text `string.find(note, "gbank", 1, true)`); all six hot-path functions are now O(1) cache reads; `GetBanks()` derives the banker list by iterating `memberRoster` rather than calling `GetGuildRosterInfo()` again. Location: Guild.lua.

- **Byte-by-byte checksum removed from outgoing messages** — Every comm send ran a rolling polynomial checksum over the entire serialized payload (15–50KB) in Lua, costing up to 15ms per large inventory delta. The checksum provided no meaningful protection (WoW uses TCP; AceSerializer self-validates on parse failure; any sender can forge a valid checksum). Fix: `SerializeWithChecksum()` now returns the raw serialized string. `DeserializeWithChecksum()` is unchanged and still falls back to plain `Deserialize()` when no checksum is found, ensuring backward compatibility with older clients. Location: Core.lua.

- **`ApplyDelta()` reduced from 5 item passes to 2** — Three "defensive" `Aggregate()` dedup passes ran after `ApplyItemDelta()` for each of bank, bags, and mail independently (3 passes). These guarded against duplication bugs fixed by STALE-INDEX-FIX, DUPLICATION-FIX, and DUPLICATION-FIX-003; any remaining edge case is caught by the hash-mismatch self-heal cycle. The final recalculation called `Aggregate(bank, bags)` then `Aggregate(result, mail)` — the second call re-iterated the full bank+bags set (2 passes total). Each defensive pass also sorted all item keys unnecessarily (only the aggregated `current.items` is ever rendered). Net reduction: 5 passes → 2 passes, 3 unnecessary sorts eliminated. For a banker with 200 bank + 150 bag items, this is ~1750 iterations + `GetItemKey()` calls + table allocations saved per received delta. (PERF-022) Location: DeltaComms.lua `ApplyDelta()`.

- **Per-login `RecalculateAggregatedItems()` migration removed** — The deferred block in `Database:Load()` ran an "AGGRESSIVE FIX" unconditionally 0.5s after every login: cleared `alt.items` and called `RecalculateAggregatedItems()` (5 Aggregate passes) for every stored banker alt, plus a dedup pass for every synced alt. This was papering over item-count duplication bugs resolved in v0.9.6; all users are on v0.9.6 or later. Fix: removed the call, the dedup block, and `RecalculateAggregatedItems()` from Bank.lua entirely (no remaining callers). Three cheap guarded migrations (slot init, inventoryHash backfill, inventoryUpdatedAt backfill) are retained — they short-circuit in O(1) for already-migrated alts. (PERF-023) Locations: Database.lua, Bank.lua.

- **`ComputeItemDelta()` O(N²) fallback replaced with O(k) lookup** — When link normalization failed to match a new item to any old item (Fallback 2 / deep ID fallback), the function scanned all `oldItems` in a `for _, item in pairs(oldItems)` loop for each unmatched new item. After a match was found, a second O(N) reverse scan of `oldByKey` located and removed the matched entry by value. Fix: a per-ID candidate list `oldByIDList[idStr]` is built during the existing `oldByIDOnly` loop, storing each item's reference and its exact key in `oldByKey`. Fallback 2 is now an O(1) hash lookup + O(k) walk where k = number of items sharing the same base ID (almost always 1–2). The matched key is stored on the candidate, making removal from `oldByKey` O(1) — the reverse-scan block is eliminated. (PERF-024) Location: DeltaComms.lua `ComputeItemDelta()`.

### Internal

- **Dead `Sync()` block removed from Events.lua** — A `--[[ ... --]]` block containing a defunct `TOGBankClassic_Events:Sync()` function with corrupted `e` / `nd` keyword fragments and misplaced PERF-021 code was removed.
- **`/togbank share` now prints feedback** — The command now confirms "Broadcasting mail and inventory hashes to guild." before executing, consistent with other command responses.

---

## [v0.9.14] (2026-03-24) - Inventory Sort Improvements

**Status:** Production Ready

### Improvements

- **Sort by Rarity and Sort by Level added to inventory window** — The sort button now cycles through four modes: A-Z → By Type → By Rarity → By Level. Rarity sort orders highest rarity first (epic before rare before uncommon), with A-Z as a tiebreaker. Level sort orders by required level descending, also with A-Z as a tiebreaker. Location: `Item.lua Sort`; `UI/Inventory.lua`.

---

## [v0.9.13] (2026-03-23) - Request Index Flood Fix & UI Polish

**Status:** Production Ready

### Bug Fixes

- **Request index flood eliminated for large request logs** — Three compounding issues caused guilds with large request lists (500+ requests, 85+ index chunks) to flood guild chat when multiple peers responded to the same index query simultaneously:
  - **Duplicate drain on re-query** — New queries arriving while an 85-chunk drain was already in progress were coalescing and re-queuing a full second copy of the index on top of the active drain, repeating indefinitely. `flushIndexQueue` now drops the re-send when a guild-broadcast drain is already in flight. Location: `RequestLog.lua flushIndexQueue`.
  - **Multi-peer simultaneous send** — All peers responded at the same fixed delay, causing N×85 chunks from N peers. Index responses now use random jitter (20–40s instead of fixed 20s), and a first-responder rule cancels a peer's pending send if it sees another peer's `togbank-ri` already draining — one responder covers the whole guild. Location: `RequestLog.lua EnqueueIndexResponse`, `ReceiveRequestsIndex`.
  - **First-responder starvation** — Each incoming chunk from an active drain was restarting the suppression timer, permanently blocking other peers. A sliding suppression window (`indexResponseSuppressedUntil`) is now extended per chunk and expires ~3s after the last chunk arrives, at which point all peers compete fairly via jitter. Location: `RequestLog.lua`.

- **"Broadcasted hash for \<alt\>" respects Mute Sync Progress Messages** — The message printed during `/togbank share` was always shown regardless of settings. Now gated behind `IsSyncProgressMuted()`. Location: `Guild.lua Share`.

- **"Syncing requests with guild…" respects Mute Sync Progress Messages** — Same fix as above for the message printed during `/togbank sync`. Location: `Chat.lua PerformSync`.

---

## [v0.9.12] (2026-03-20) - Stale Banker Indicators, Version Check & Bug Fixes

**Status:** Production Ready

### Bug Fixes

- **Quality border colors fixed for all gear** — Three compounding issues caused weapons and armor to always show a white quality border regardless of actual rarity. (1) `GetItems` Branch 1 used `GetItemInfoInstant` (no rarity field) — fixed in v0.9.10 by switching to `GetItemInfo`. (2) `Item:Sort` was defaulting nil rarity to `1` (common/white) via `rarity = rarity or 1` before `DrawItem` ran — this masked nil rarity with a truthy value, making the sync/async fallbacks in `DrawItem` unreachable. The sort comparators already handle nil safely, so the assignment was both unnecessary and harmful; it has been removed. (3) Remote-synced gear not yet in the client cache still had nil rarity even after fix (1) — `DrawItem` now has a sync fallback (`GetItemInfo(item.Link)` at draw time) and an async fallback (`ContinueOnItemLoad` → `GetItemInfo(item.Link)` → `SetVertexColor`) for items that load into cache after first render. All lookups use the full item link; ID-based lookup is intentionally excluded because the base item ID returns the wrong rarity for suffixed gear. Locations: Item.lua `Sort` (~line 449); UI.lua `DrawItem` (~line 145).

- **Mail item tooltip fixed** — Items sourced from the mailbox were stored with a double `item:item:…` prefix, causing tooltips to fail and show a blank name. Location: UI.lua mail item handling.

- **Empty index responses after `/togbank wipe` eliminated** — After a wipe the local requests hash is `00000000`. We were still responding to peers' index queries with an empty index. Peers now skip responding when their own hash is zero (nothing to offer). Location: Chat.lua index query respond condition.

- **False `[WARN] Invalid request version 0` after `/togbank wipe` removed** — Version `0` is valid for a freshly wiped or initialised client; the out-of-range check now exempts it. Location: RequestLog.lua `GetRequestsVersion`.

- **P2P "peer acknowledged" message respects Mute Sync Progress Messages** — The "P2P: Peer X acknowledged Y – will send delta" line was always printed to chat regardless of settings. It is now gated behind the Mute Sync Progress Messages checkbox. Location: Chat.lua P2P acknowledgement handler.

### Improvements

- **Stale banker tab indicators** — Banker tabs in the inventory window now turn red when a peer has broadcast a newer hash for that banker (i.e. the alt is HLR-pending per the same definition as `/togbank hashdebug`). Hovering a red tab shows a tooltip explaining that other guild members have newer data and current availability may not be accurate. The staleness check (`Guild:IsAltSyncPending`) covers both inventory and mail hash mismatches, missing content, and is the single source of truth used by both the tab color and the tooltip — consistent with `/togbank hashdebug` output. Location: Guild.lua `IsAltSyncPending`; UI/Inventory.lua `DrawContent`.

- **`/togbank versioncheck`** — Broadcasts a version check to all online guild members using VersionCheck-1.0 (`VC:FireBatch`), waits 21 seconds for responses, then prints a sorted list of who is running which version. Because it piggybacks on VersionCheck-1.0's own protocol (`VC10_REQ`/`VC10_RSP`), it reaches members running any version of the addon that had the library — including those running versions too old to receive newer custom protocols. Replaces `/togbank versions`, which only saw members who had sent a message since login. Location: Chat.lua `versioncheck` command handler.

- **Version displayed in inventory window title** — The main inventory window title now shows the addon version (e.g. "TOGBankClassic v0.9.12") via `GetAddOnMetadata`. Location: UI/Inventory.lua `DrawWindow`.

### Performance

- **`NormalizeRequestList` dirty flag** — The function now skips its O(N) full-table rebuild when request data hasn't changed since the last run. Previously it was called twice per index send (once via `EnsureRequestsInitialized`, once directly) even in steady state. It now runs only after actual data changes: first load, peer data merges, and migrations. Location: RequestLog.lua `NormalizeRequestList`.

### Internal

- **Debug system overhaul** — All `DebugComm` calls converted to `Debug(category, tag, …)`. P2P, COMMS, SYNC, and REQUESTS categories cleaned up. New `REQUESTS/PROTO2` tag covers `togbank-ri` / `togbank-rd2` compact protocol traffic.
- **`/togbank versions` removed** — Superseded by `/togbank versioncheck`, which reaches all guild members regardless of when they last sent a message.
- **Removed `QueryRequestsSnapshot` shim** — No callers remain; the modern `QueryRequestsIndex` replaced it entirely.
- **PERF-002: removed `data.requests` from `togbank-dv2` broadcasts** — The request version/hash field was included in every periodic inventory broadcast but never consumed by receivers. Removed to avoid confusion and marginal bandwidth waste.

---

## [v0.9.10] (2026-03-19) - 60% Bandwidth Reduction for Request Sync

**Status:** Production Ready

### Performance

- **Request sync uses ~60% less bandwidth** — The request index and per-record wire format has been rewritten from verbose key-value dicts to compact positional arrays. Two new prefixes carry this traffic:
  - `togbank-ri` — requests index as a flat positional array (`{version, liveCount, id, updatedAt, ..., tombId, tombTs, ...}`), eliminating per-field string keys across hundreds of IDs.
  - `togbank-rd2` — individual request records as positional arrays, avoiding repeated field-name overhead when syncing large request logs.

  Guilds with 500+ requests will see the most noticeable improvement during initial sync and after being offline.

### Internal

- **Request IDs changed to 14-char random hex** — The previous `actor:random` composite format has been replaced with 14 random hex characters. Existing requests retain their old IDs.
- **Removed `statusUpdatedAt` field** — The per-request status-change timestamp field has been dropped from the wire format and storage schema.
- **Removed dead protocol slots** — `togbank-dr` and `togbank-dc` (DELTA-006 delta chain replay) were never triggered by current clients and have been removed.

---

## [v0.9.8] (2026-03-19) - Request Expiry Fixes & Dropdown Improvements

**Status:** Production Ready

### Bug Fixes

- **Expiry clock anchored to wrong timestamp** — `PruneRequests` used `updatedAt` as the 30-day expiry anchor, but `updatedAt` is bumped on every sync so done requests never actually aged out. The anchor is now `statusUpdatedAt`, which only changes when the request is fulfilled, cancelled, or completed. The 30-day clock now starts when the request was actually finished.
- **Expired requests re-imported from peers** — Stale done requests received from peers running older clients were being merged back into the local database, undoing the prune. They are now tombstoned on arrival (backdated timestamp so the tombstone itself also expires within 30 days).
- **Pruning skipped on login** — `PruneIfNeeded` was not called when the addon loaded from SavedVariables, so expired requests lingered until the first periodic share timer fired (~3 minutes). Pruning now runs immediately during `Guild:Init`.

### Improvements

- **Requester/Banker dropdowns show full history** — Previously only requesters and bankers with at least one open request appeared in the filter dropdowns, making it impossible to filter by someone whose requests were all fulfilled or cancelled. The dropdowns now show everyone, split into two labelled sections: "-- Open requests --" (active names, sorted by open count) and "-- History --" (completed-only names, sorted by total count).

### Internal

- **Removed legacy full-snapshot request sync** — The `type="requests"` snapshot protocol (replaced by the index/by-id protocol seven weeks ago) has been removed. A thin shim remains in `QueryRequestsSnapshot` to avoid crashes on mixed-version guilds during the transition.
- **`/togbank reqscan`** — New diagnostic command showing total/done/expired request counts, status breakdown, and `statusUpdatedAt` age distribution (0-7d, 7-14d, 14-21d, 21-30d, >30d).
- **COMMS log clarity** — `togbank-rd` log lines now include the subtype (idx / by-id) immediately before the byte-count line, making it easier to correlate log output with protocol activity.

---

## [v0.9.7] (2026-03-18) - Request Retirement Fix & Status Bar Cleanup

**Status:** Production Ready

### Bug Fixes

- **Expired requests never pruned** — Fulfilled and cancelled requests from 30+ days ago were accumulating indefinitely. `PruneIfNeeded` was only called after mutations, never on a timer, so requests were never cleaned up on clients that hadn't recently submitted or fulfilled a request. It now runs automatically every ~3 minutes via the periodic share timer.

### Improvements

- **Status bar network labels renamed** — The network counters in the inventory status bar are now labelled `Tx:` (outgoing sends), `Rx:` (P2P data fetches), and `Bcast:` (sync broadcast queue), replacing the cryptic `send:`, `P2P:`, and `q:` labels.
- **Status bar layout** — When the window is too narrow to show all three sections, the right section drops first (was: center). Left + center are shown until even narrower, then left only.
- **Status bar refactored into StatusBar.lua** — All status bar logic (formatters, inventory summary, network parts, ticker lifecycle, hover callbacks) is now in `Modules/UI/StatusBar.lua`. `Inventory.lua` retains only two lines of status bar surface.

---

## [v0.9.6] (2026-03-16) - Request Sync Throttle Overhaul & Network Status Bar

**Status:** Production Ready

### New Features

- **Request sync throttle overhaul** — The requests-index pipeline was reworked to eliminate multi-minute CTL backlogs on guilds with 1000+ requests:
  - **Deduplicating response drain** — Replaced `SendRequestsById` with a `queriedRequests` map. Duplicate requests for the same ID from the same peer are dropped; requests from two different peers are automatically upgraded to a guild broadcast. Responses drain at one batch per second, gated on CTL queue depth.
  - **Coalesced index responses** — Multiple guild members querying the requests index within a 20-second window now trigger a single response instead of N. If different senders query, one guild broadcast replaces N individual whispers; sends are also deferred while the CTL queue is busy.
  - **Chunked index sending** — Requests-index payloads are now split into chunks of 20 IDs sent 1 second apart (previously: one ~400-packet burst). Receivers can begin fetching missing requests after the very first chunk arrives. Old clients (v0.9.5 and below) remain compatible.
- **Network status bar** (opt-in) — The inventory window status bar now optionally shows live sync activity. Enable in Options -> General -> "Show Network Status in Status Bar":
  - Left: send / queue / fetch counters
  - Centre: "Sending [type] to [recipient]" (next queued CTL message)
  - Right: "Backlog: N packets[, N recipients][, N requests]"
  - Sections hide automatically when the window is too narrow to show all three without overlap.
- **/togbank netq** — New expert command showing a full CTL queue breakdown by message type and recipient count.
- **Request count in status bar** — The Requests window now shows the total request count alongside the filtered count (e.g. "3 / 47").

### Bug Fixes

- **Self-query loop on login** — If the logged-in character was the only eligible banker, `QueryAltPullBased` would whisper itself, triggering a useless sync loop. Self is now excluded from the banker search.

### Diagnostics

- Hash values in request-index log lines are now shown in hex, consistent with the rest of the codebase.
- Outgoing COMMS log messages now include the recipient.
- Requests-by-id queries and responses (both directions) are now logged under REQUESTS/SEND and REQUESTS/RECEIVE.
- Requests-index log lines now show both the querier's hash and the local hash side-by-side, making SYNC-011 hash-match decisions easier to trace.

---

## [v0.9.5] (2026-03-16) - Request Sync Diagnostics & UI Polish

**Status:** Production Ready

### ✨ New Features

- **Network queue status bar** — The main window status bar now shows live network activity: pending sends (`send:1/3`), outbound sync queue depth (`q:2`), P2P data fetches in flight (`fetch:1`), and request index sync state. During batch ID syncs the progress is shown as `r:2/7` (current batch / total batches).
- **Descriptive request sync status** — The request index query indicator in the status bar now shows the target player name (e.g. `Querying requests index from Skywise`) instead of the cryptic `r:idx` label.
- **/togbank versions restored** — Addon version tracking is now populated from two sources: banker hash-list-broadcasts and non-banker requests-index queries, so `/togbank versions` shows all online guild members regardless of role.

### 🐛 Bug Fixes

- **Request sync stalling on large guilds** — Three timing fixes for guilds with 1000+ requests:
  - `INDEX_INFLIGHT_TIMEOUT` increased from 30 s to 180 s — the old value expired before a 20-batch sync (20 × 5 s = 100 s) could complete, causing the sync to silently abort mid-flight.
  - `REQUESTS_BY_ID_BATCH_DELAY` increased from 2 s to 5 s — gives the responding peer more time to reply before the next query batch arrives.
  - requests-index inFlight fallback timer increased from 5 s to 10 s — reduces false "guild in sync" clears when the peer's send queue is momentarily congested.
- **Mail age showing "20000 days ago"** — `lastScan = 0` is truthy in Lua, so `time() - 0` produced a timestamp relative to the Unix epoch. `GetMailDataAge` now treats `lastScan = 0` as absent data.
- **Requests date column misaligned** — Dates in open/pending requests appeared shifted left of fulfilled/cancelled dates because centre-alignment repositions shorter strings. All rows now receive a same-width invisible prefix so the date text centres identically across all states.

### 🔍 Diagnostics

- **Outgoing requests-index responses now logged** — Previously only incoming queries were logged; the response send was silent, making it impossible to confirm whether we had responded.
- **Hash values shown in requests-index log** — The query log line now appends `(their:NNNN ours:NNNN)` to help diagnose SYNC-011 hash-match decisions.

---

*Older releases (v0.9.4 and earlier) are archived in [CHANGELOG_ARCHIVE.md](CHANGELOG_ARCHIVE.md).*
