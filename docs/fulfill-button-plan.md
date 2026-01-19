# Fulfill Button Implementation Plan

## Overview
Add a "Fulfill" button to the Actions column in the Requests window that allows guild bank alts to prepare mail with requested items for the requester.

## Key Approach
Using the BulkMail2 pattern:
```lua
PickupContainerItem(bag, slot)     -- Pick up item from inventory
ClickSendMailItemButton(slotIndex) -- Attach to mail slot
SendMailNameEditBox:SetText(name)  -- Set recipient
-- User clicks Send to confirm
```

## Files to Modify

### 1. `Modules/Bank.lua` - Add item search helpers
```lua
-- Find items by name in bags (0-4)
function TOGBankClassic_Bank:FindItemsByName(itemName)
function TOGBankClassic_Bank:CountItemInBags(itemName)
```

### 2. `Modules/Mail.lua` - Add fulfill functions
```lua
-- Check if request can be fulfilled
function TOGBankClassic_Mail:CanFulfillRequest(request, actor)
  -- Returns: canFulfill, reason, itemsInBags

-- Prepare mail with items attached
function TOGBankClassic_Mail:PrepareFulfillMail(request)
  -- Sets recipient, attaches items from inventory
  -- Returns: success, message, attachedCount
```

### 3. `Modules/UI/Requests.lua` - Add button UI
- Add `FULFILL_ICON` constant (mail icon)
- Widen Actions column: 110 -> 140
- Add `fulfillButton` in `EnsureRow()` after deleteButton
- Add visibility/enable logic in `DrawContent()`
- Add click handler calling `PrepareFulfillMail()`

### 4. `Modules/Events.lua` - Refresh UI on mail state
- Add `RefreshRequestsUI()` to MAIL_SHOW handler
- Add `RefreshRequestsUI()` to MAIL_CLOSED handler

## Button States

| State | Condition | Appearance |
|-------|-----------|------------|
| Hidden | Not a bank alt, or request fulfilled | Not shown |
| Disabled | Bank alt, not at mailbox | Grayed, tooltip: "Open a mailbox to fulfill" |
| Disabled | Bank alt, at mailbox, items in bank only | Grayed, tooltip: "Pick up items from bank first" |
| Enabled | Bank alt, at mailbox, items in bags | Active, tooltip shows item count |

## User Flow
1. Bank alt opens Requests window
2. Sees "Fulfill" button on pending requests (grayed if not at mailbox)
3. Goes to mailbox, opens it
4. Button becomes active (UI auto-refreshes on MAIL_SHOW)
5. Clicks "Fulfill" button
6. Items are attached to mail, recipient is set
7. Status bar shows "Attached X [Item] for Requester. Click Send to complete."
8. User clicks Send in mail UI
9. Existing SendMail hook updates fulfilled count automatically

## Edge Cases
- **Partial fulfillment**: Attach what's available, show message "Attached 15 of 20..."
- **Multiple stacks**: Attach up to ATTACHMENTS_MAX_SEND (12) slots
- **Mail already has items**: Should warn user or clear first
- **Item name matching**: Case-insensitive exact match via `GetItemInfo(link)`

## Verification
1. Create a request as a regular guild member
2. Log onto bank alt
3. Verify button hidden when not a bank
4. Verify button grayed when away from mailbox
5. Verify button grayed when items only in bank
6. Move items to bags, go to mailbox
7. Click Fulfill - verify items attach and recipient set
8. Click Send - verify fulfilled count updates
