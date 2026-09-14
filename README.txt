================================================================================
TOGBankClassic - Guild Bank Inventory Management for WoW Classic Era & TBC
================================================================================

Version: 1.5.1
Authors: Dominion-Myzrael, GrumpyPlayers (SG Soul), Lothsahn, Huntmehuntme,
         Pimptasty
Website: https://www.curseforge.com/wow/addons/togbankclassic

================================================================================
WHAT IS TOGBANKCLASSIC?
================================================================================

TOGBankClassic is a powerful addon that allows you to view and manage the
combined inventory of multiple guild bank characters without logging into
each one. Perfect for guilds that use character banks instead of (or in
addition to) the guild vault system.

SUPPORTED GAME VERSIONS:
- WoW Classic Era
- WoW The Burning Crusade

Both are published from the same source, so the features, commands and
interface are identical on either version. CurseForge serves the correct
build automatically for whichever version you install it under.

KEY FEATURES:
- One Guild Bank window: every bank character's items as one sortable list,
  with filters across the top (search, bank, type, slot, quality, level,
  usable by me), plus Bankers, Requests and Log tabs
- Search across all bank characters simultaneously
- Request items from guild banks via in-game mail
- One Fulfill button that collects from the bank AND attaches to mail; a
  Fulfill Oldest envelope that works the queue for you, one mail per person
- A Mailbox window: your inbox as rows, take an item with a click, take only
  what open orders need, return a mail to its sender
- Bank characters can hide items from the guild (right-click), or every
  soulbound item at once
- A bank log: deposits, withdrawals, money and every request event, with who
  was on each side - and handed to TOGTools for the long history
- Guild-wide request limits for fair resource distribution (officers only)
- Automatic synchronization with other guild members using the addon
- Catching up on a bank you already hold sends only what changed
- Bank contents sent as compact numbers, not item links - 85% less data
- Every bank character has a permanent four-digit number, so the guild-wide
  check-in is a few hundred bytes and an offer is a single message
- No transfer at all between members whose copies already match
- The Bankers tab and bank tabs tell you whether your copy is current
- A bank character is told when their latest update has reached the guild,
  so they know when it is safe to log off
- Sync pauses in a raid group (and says so); a setting keeps it running
- Persistent debug logging system for troubleshooting
- Works seamlessly with multiple bank alts

================================================================================
INSTALLATION
================================================================================

METHOD 1: CURSEFORGE APP (RECOMMENDED)
---------------------------------------
The easiest and most reliable way to install and keep TOGBankClassic updated:

1. Download and install the CurseForge App from:
   https://download.curseforge.com/

2. Open the CurseForge App and go to "World of Warcraft"

3. Select your game version from the dropdown -- either
   "World of Warcraft Classic Era" or "World of Warcraft Burning Crusade"

4. Go to the "Get More Addons" section

5. Search for "TOGBankClassic"

6. Click "Install" on the TOGBankClassic addon

7. Launch the game through the CurseForge App
   (or type /reload if already in-game)

8. The addon is now installed and will automatically update when new
   versions are released!

BENEFITS OF CURSEFORGE APP:
- Automatic updates when new versions are released
- Easy one-click installation
- Manages addon dependencies automatically
- Safe and verified addon downloads
- Works with all your WoW addons in one place


METHOD 2: MANUAL INSTALLATION (NOT RECOMMENDED)
------------------------------------------------
Only use this method if you cannot use the CurseForge App:

1. Download TOGBankClassic from CurseForge:
   https://www.curseforge.com/wow/addons/togbankclassic/files

2. Extract the downloaded ZIP file

3. Copy the TOGBankClassic folder to your WoW addons directory:
   Classic Era:      World of Warcraft\_classic_era_\Interface\AddOns\
   Burning Crusade:  World of Warcraft\_anniversary_\Interface\AddOns\

   Download the file matching your game version -- CurseForge lists a
   separate Classic Era and Burning Crusade build on the Files page.

4. Restart World of Warcraft (or type /reload if already in-game)

5. The addon is now installed and ready to configure

NOTE: Manual installation means you must manually download and install
      updates. You will not receive automatic update notifications.

================================================================================
SETUP INSTRUCTIONS
================================================================================

FOR GUILD BANK CHARACTERS:
---------------------------
1. Log in with your guild bank character
2. Make sure the character is in your guild
3. Add "gbank" to the character's Public Note OR Officer Note
4. Type /reload to refresh the addon
5. Press ESC -> Interface -> AddOns -> TOGBankClassic
6. Click the [-] icon to expand the Bank section
7. Tick "Enable for <character>" - that is the one setting that lets this
   character's bank be scanned and shared. (It is on by default, so usually
   there is nothing to do here. The other tick in that section, "Report
   contributions", is unrelated: it only controls the "Received X from Y"
   chat lines when you open donation mail, and leaving it off does NOT stop
   your bank being shared.)
8. Open your bank and then CLOSE it - the scan runs when the bank closes.
   The guild picks it up on the next 10-minute check-in, or straight away if
   you type /togbank share
9. Type /togbank roster - your bank character is listed with a four-digit
   number beside it (assigned automatically; nothing to type anywhere)
10. The addon will now automatically share this character's inventory!
11. Optional: write what this bank keeps beside the marker ("gbank herbs,
    potions") and it shows in the Bankers tab's Stores column

VIEW-ONLY BANK CHARACTERS (e.g. a raid bank):
---------------------------------------------
To make a bank character visible to everyone but NOT requestable (its items
show in inventory/search/tooltips, but guild members can't send requests for
them), add a view-only marker to its note alongside "gbank". For example, set
the Public/Officer Note to:  gbank viewonly
Also accepted: "gbank readonly", "gbank read-only", or the compact "gbankro".
Type /reload after changing the note.

FOR REGULAR GUILD MEMBERS:
---------------------------
1. Just install the addon - no configuration needed!
2. Click the minimap button to open the Guild Bank window
3. Type /togbank sync to manually request latest data from bank characters
4. The addon automatically syncs every 10 minutes

================================================================================
BASIC USAGE
================================================================================

OPENING THE INTERFACE:
  Click the minimap button (shift-click it for the options).
    Opens the Guild Bank window: every bank character's items as ONE
    sortable list, with Browse, Bankers, Requests and Log tabs. The ? beside
    Close explains each tab.
  /togbank
    The same as the minimap button: opens the Guild Bank window.
  /togbank legacy
    Opens the old Inventory window, a tab per bank character, while it lasts.

SEARCHING FOR ITEMS:
  Type in the search box across the top of the Browse tab; every word you
  type has to appear somewhere in the row. Narrow further with the filters
  beside it (bank, type, subtype, slot, quality, level range, usable by me);
  Clear puts them all back. Click a column heading to sort by it. The Banker
  column says which bank character holds the item, with a dot for that bank's
  status (green current, red behind, yellow an update on its way).

REQUESTING ITEMS:
  Click an item's row to open the request dialog and send a mail request to
  the bank character. They'll see your request the next time they log in.

  NOTE: Guild officers can configure maximum request limits to ensure fair
  distribution of resources. If a percentage limit is set, you may not be
  able to request the full available quantity. The interface will show the
  maximum allowed amount (e.g., "Available: 100 (Max: 50% = 50)").

FULFILLING ORDERS (bank characters):
  Open the Guild Bank window's Requests tab (clicking the mail frame's Send
  Mail tab opens it for you) and click "Fulfill" on an order. The button does
  the right thing for wherever you are standing:

  - At your BANK: each click pulls out what the order still needs. If the
    stack is bigger than the order, the spare is split straight back into
    the bank. If your bags are full, the click swaps a stack no open order
    needs into the bank to make room (never your hearthstone). No free bank
    slot, and nothing left to collect, are each reported rather than failing
    quietly.
  - At a MAILBOX: each click attaches the items to the mail, splitting
    stacks as needed; the recipient is filled in for you. Click Fulfill on
    several of one person's orders and each is added to the same mail (up
    to 12 attachments), then Send once - every order on it is marked filled.
    The envelope (Fulfill Oldest) does this on its own: the oldest order
    and that person's other orders you can fill from your bags go out as
    one mail - including ones that need a stack split. One click does every
    split at once (it tells you if you need free bag slots first), the next
    attaches everything, the last sends.

  The game never lets you have the bank and a mailbox open at once, so the
  normal flow is: collect at the bank, walk to the mailbox, keep clicking.
  At the mailbox, the Mailbox window's Take Needed button pulls what your
  open orders are still short of out of the mail first.

  After you close the mailbox, the bottom bar of every window tells you
  whether that update has reached the guild yet: red until it has been sent
  to someone, amber once it has, green when a guildmate confirms - stay
  online while it is red. Starting the logout countdown while it is red
  gives you a chat warning.

FINDING A REQUEST:
  The Requests tab has ONE search box beside the Requester and Bank
  dropdowns. Type part of a name, an item or a date; every word you type
  must appear somewhere in the row's date, requester, bank or item, and it
  narrows on top of the dropdowns. The X in the box clears it. A cancelled
  request's date glows gently - mouse over it for the reason.

MANUAL SYNC:
  /togbank sync
    Manually requests the latest inventory data from all online guild
    members who have the addon installed.

SHARING YOUR DATA:
  /togbank share
    Manually announces your bank character's current version to the guild.
    Anyone holding an older copy asks you for it straight away. This happens
    automatically every 10 minutes and whenever you open the Inventory window;
    run it yourself right after a bank visit if you want the guild to see it
    sooner. Hiding or showing an item announces itself the moment it is done.

HIDING ITEMS FROM THE GUILD (bank characters):
  On your own bank's rows - your tab of the old Inventory window, or your
  bank on the Browse tab - right-click an item to hide it. It stays in your
  list greyed out with a red mark; to everyone else it is as if you do not
  have it. Right-click it again to show it. To hide every soulbound item at
  once, tick "Hide soulbound items from the guild" in the Bank settings.
  To the bank log, hiding looks like a withdrawal and showing like a deposit.

THE BANK LOG:
  The Log tab shows what has moved in and out of the guild bank, newest
  first: deposits and withdrawals as each bank character publishes, money,
  and every request as it is placed, mailed, handed over, cancelled or
  reopened - with who was on each side where the addon can tell. A mailed
  donation is logged as a deposit, naming the sender, when the bank character
  takes it out of the mail. Type a name, an item or an action in the search
  box, or narrow by date with Since and Until. Only the most recent entries
  are kept here; if you run TOGTools, its Logs > Guild Bank tab keeps the
  long history automatically.

================================================================================
COMMAND REFERENCE
================================================================================

BASIC COMMANDS:
---------------
/togbank
  Opens the Guild Bank window, the same as the minimap button

/togbank help
  Displays help information and command list

/togbank version
  Shows your current TOGBankClassic version

/togbank sync
  Manually sync to receive latest data from online users
  (Automatic sync happens every 10 minutes)

/togbank share
  Manually announce your bank character's current version to the guild.
  Anyone holding an older copy requests it from you straight away.
  (Automatic every 10 minutes, and whenever you open the Inventory window)

Minimap button (click)
  Opens the Guild Bank window: every banker's items as ONE sortable list
  instead of a tab per character. Filters across the top (search, bank, type,
  subtype, slot, quality, level range, usable by me) narrow the rows as you
  change them; click a row to request it. The Bankers tab lists each bank
  character with their status, when they last published, and what they hold;
  click one to see just that bank. Also reachable from the Browse button on
  the old Inventory window. Shift-click the minimap button for the options.

/togbank legacy
  Opens the old Inventory window (a tab per bank character), while it lasts.

/togbank mailbox
  Opens the Mailbox window while you are at a mailbox. It opens by itself for
  bank characters (switch that off under Settings > General if you prefer, or
  tick the box under it to have it open on your other characters too).
  Every mail in your inbox is a row - icon, subject, how many
  attachments, sender, days left - with items a pending request needs marked
  in green. The clicks are the game's own: click a mail to open it and see
  what is on it, click an item to take it into your bags, shift-click (or
  right-click the mail) to take everything on it; the envelope at the right of
  a mail row returns that mail to its sender. Filter the rows by item,
  sender or subject;
  Take Needed collects what your open orders are short of; Take Shown collects
  everything the filter left, one after another. Cash-on-delivery mail is
  marked and left for the normal mail frame.

/togbank reset
  Resets your TOGBankClassic database (clears all stored data)


EXPERT COMMANDS:
----------------
These commands are for advanced users and guild officers. Commands are
listed alphabetically for easy reference.

/togbank compact
  Manually runs database compaction to prune old requests and log entries

/togbank debuglog [N] [filter]
  Exports last N debug log entries (default 500), optionally filtered by keyword
  Example: /togbank debuglog 100 MAIL
  Example: /togbank debuglog 1000

/togbank debuglogclear
  Clears all persistent debug log entries

/togbank debuglogstats
  Shows statistics about the persistent debug log including entry count,
  date range, and retention settings

/togbank debugtab
  Creates a dedicated chat tab called "TOGBank Debug" for debug output
  This keeps debug messages separate from your main chat tabs
  After creating the tab once, use /togbank debug to enable debug logging
  All debug output will automatically go to the debug tab

/togbank debugtabremove
  Removes the TOGBank Debug chat tab

/togbank roster
  Lists the guild's bank characters as read from your guild notes, with the
  permanent four-digit number each one has been given and the version of that
  numbering. The numbers are assigned automatically by any account that owns
  a bank character - the first time it logs in on this version, or the first
  time a new bank character's bank is scanned - and are the same on everyone's
  screen. A number is for life: a bank character that leaves and comes back
  keeps it. If a bank character shows "----" its number has not reached you
  yet, which resolves the next time any updated guildmate's check-in is heard.
  On a fresh install the first sync learns the numbers and the second sync
  uses them.

/togbank wipe
  Resets your own TOGBankClassic database

/togbank wipeall
  (OFFICER ONLY) Resets database for all online guild members
  WARNING: This affects everyone - use with caution!

/togbank wipeframes
  Forgets every saved window position and size. Open windows are recentred
  at once; sizes go back to default on the next /reload. For a window that is
  simply off screen, "Recenter All Windows" under Settings > Appearance moves
  every window to the middle without touching sizes.

/togbank helpreset
  Forgets which help (?) icons you have hovered, so they pulse again until
  you hover them


DEBUG COMMANDS:
---------------
/togbank debug
  Toggles debug mode on/off for troubleshooting
  Shows detailed information about addon operations
  Setting persists across reloads and is saved to your addon settings
  TIP: Use /togbank debugtab first to create a dedicated debug chat tab

================================================================================
BAG ADDON COMPATIBILITY (v1.3.2+)
================================================================================

The "Highlight needed items" option (available to bank characters in the
Requests window) marks the items in your bags that are needed to fill open
orders. It works with the default Blizzard bags and with the three most common
bag replacements, but the VISUAL DIFFERS depending on which one you use --
this is a limitation of what each addon lets other addons change, not a bug.

SUPPORTED BAG ADDONS:
---------------------

  Default Blizzard bags
      Items you do NOT need are dimmed. Needed items stay full colour.

  Bagnon
      Uses Bagnon's own search highlighting. Items you do not need are
      dimmed; needed items stay lit.
      NOTE: limited to the first 20 distinct items. With more open orders
      than that, only the first 20 are highlighted.

  ElvUI
      Items you do NOT need are dimmed, using ElvUI's own shading so it
      looks native. Covers both the bag and the bank window. Unticking the
      box restores everything to normal, and ElvUI's own search box keeps
      working normally while highlighting is on.

  Baganator
      Needed items get a GOLD MARKER in the top-left corner of the icon.
      Nothing is dimmed. Baganator only allows other addons to add corner
      markers, so this is the one form available there.
      You can move or remove the marker from Baganator's own customise
      window, where it is listed as "TOGBank: needed for an order".

RUNNING MORE THAN ONE:
----------------------
Bag addons are checked in this order: ElvUI, Baganator, Bagnon, then the
default bags. The first one actually drawing your bags wins.

If you run Bagnon underneath ElvUI with ElvUI's own bag replacement turned
OFF, highlighting correctly falls through to Bagnon -- ElvUI is only used
when it is genuinely the addon drawing your bags.

TROUBLESHOOTING:
----------------
If the checkbox does nothing:
- Confirm your character is a bank character (its guild note contains
  "gbank"); the option is only offered to bank characters.
- Confirm there are open orders assigned to that bank character. With
  nothing to fill, there is nothing to highlight.
- Enable /togbank debug and look for REQUESTS category messages -- the
  addon logs which bag addon it detected and chose.

================================================================================
HOW SYNCING WORKS (v1.4.0+)
================================================================================

Bank contents are sent as compact numbers rather than as item links. Each item
travels as its ID plus a count and a couple of small numbers, and YOUR client
rebuilds the item from that - so nothing is transmitted that your game already
knows. Measured on a live guild across 227 items: 19,740 bytes of the old
format against 2,873 of the new, an 85% reduction.

HOW IT WORKS (v1.4.1):
----------------------
1. A bank character's contents are scanned when you CLOSE the bank window. If
   anything changed since the last scan they get a new VERSION STAMP; if
   nothing changed, nothing is stamped and nothing is sent. The stamp carries
   the time it was published, so any two copies can be compared at a glance.
2. Every bank character has a permanent four-digit NUMBER (see /togbank
   roster), so the guild-wide check-in - sent at login, every 10 minutes,
   whenever you open the Inventory window or type /togbank share, and after a
   hide/show on your bank - is just "number + version" per bank, a few hundred
   bytes. (Closing the bank scans and stamps; the next check-in carries it.)
3. Anyone who hears a check-in and holds a NEWER version of one of those banks
   replies with a single short message naming the bank numbers they can
   improve. And a check-in from a bank character announcing a new version is
   itself an offer: everyone behind on it asks straight away, within seconds.
4. Before asking for the data, the addon asks a few of those who offered which
   version they hold, and takes the newest - from the bank character itself
   when it answers. The request names that exact version.
5. The two clients agree the transfer privately and the contents are sent to
   the member who asked, not to the whole guild. Downloads from different
   guildmates run at the same time; a player sends to three at a time and
   tells anyone else their place in the queue - nobody is refused.
6. The short back-and-forth that sets a transfer up travels on a fast lane of
   its own, separate from the bulk data, so it is answered even while the
   other player is busy sending to someone else.

The version stamp is produced ONCE, by the bank character that did the scan,
and is carried unchanged by everyone else. Nobody else recalculates it. This is
what stops members overwriting each other's copies with stale data, and it is
why simply looking at a bank no longer generates guild traffic.

BANK STATUS:
------------
On the Bankers tab each bank character's Status column says whether your copy
is current; in the old Inventory window the same thing is the tab's colour.
Hover it for who said what:
- CURRENT (yellow tab): your copy is the newest anyone who can supply it has
  mentioned.
- OLD FORMAT (red tab, "predates the current format"): that bank has not been
  scanned since its owner updated. It stays so until they open and close
  their bank once.
- BEHIND (red tab, "a newer copy was published"): someone has a newer version
  than you and it is being fetched. It goes Current the moment it arrives.
- NEWER COPY UNREACHABLE (grey): the only newer copy is held by a guildmate
  whose addon is too old to send it. It goes Behind as soon as someone on
  the current version has it.
- NO DATA (grey): nobody online has published that bank yet.
Only someone who can actually supply a newer copy can turn a bank red; a
claim from a guildmate on an older version is ignored. Your OWN bank can go
red on one computer only when a shared account has published a newer copy
from another - hover it, it tells you what to open.

BENEFITS:
---------
- 85% less data than the previous format (measured, not estimated)
- Check-ins and offers a fraction of their former size
- No transfer at all when nothing has changed
- A bank character's update reaches everyone online within seconds
- Bulk transfers go privately to whoever asked, keeping guild chat clear
- Fully automatic - no configuration required
- Persistent debug logging for troubleshooting

MONITORING SYNC:
----------------
Syncing runs automatically in the background. If you suspect issues, enable
debug logging with /togbank debug (optionally /togbank debugtab first to direct
output to a separate chat tab) and watch for DELTA / SYNC / COMMS category
messages. Use /togbank debuglog to export a recent slice of the persistent log
for bug reports.

SYNC PAUSES WHILE YOU ARE IN A RAID GROUP. Nothing is sent or received until
you leave, so raid addons keep the chat channel to themselves. You are told
once in chat when it pauses, and every window's status bar reads "Sync paused:
in a raid group" for as long as it lasts. It resumes on its own when you leave.
To keep syncing in raids anyway, tick "Keep syncing in a raid group" under
Settings > General (off by default).

COMPATIBILITY:
--------------
IMPORTANT: v1.4.0 changed the format bank data is sent in, and it is NOT
backwards compatible.

- v1.4.0+ clients exchange bank data with each other normally.
- Bank data from a pre-v1.4.0 client CANNOT be read. It is ignored rather than
  misread, so nothing is corrupted - but you will not see that character's bank
  contents until they update.
- When a BANK character is on an older version, the addon tells you by name and
  asks you to have them update. It says this once per character per session.
- Everything else - orders, requests, the roster - continues to work across
  versions.

The practical effect during a rollout: whoever updates first sees less bank
data, not more, until their bank characters follow. The addon names exactly who
to chase.

v1.4.1 changed the check-in and offer messages again. A v1.4.0 client cannot
read them and simply stops hearing offers from anyone who has updated - nothing
breaks for them, they just stop getting newer copies until they update. After
updating, open and close each bank character's bank once, so its contents are
published with a version stamp - until then that bank's tab is red for
everyone. The first bank account to do that (or simply to log in, if it already
scanned on v1.4.0) numbers EVERY bank character in the guild in one go, and
everyone else picks the list up automatically from the next check-in they hear.

v1.5.0 changed how bank contents are handed over (only what changed travels,
checked against the bank character's own fingerprint). Bank contents no longer
travel between v1.5.0 and older clients in either direction: a guildmate still
on v1.4.1 stops receiving bank contents from anyone who has updated and is not
asked for theirs. Nothing breaks for them - requests, the roster and everything
else still work across versions - they simply stop seeing current bank
contents until they update, and a banker sees their requests marked with the
old version number. After updating, bank characters: open and close your bank
once so its contents are published in the new form. EVERYONE IN THE GUILD
SHOULD UPDATE.

DEBUG LOGGING:
--------------
v0.8.0 introduces persistent debug logging:
- Debug messages saved to SavedVariables
- Survives reloads and logout
- Use /togbank debuglog to export recent logs
- Use /togbank debuglogstats to see log statistics
- Use /togbank debuglogclear to clear old logs
- Use /togbank debugtab to create dedicated chat tab for debug output

================================================================================
TROUBLESHOOTING
================================================================================

PROBLEM: I don't see any guild bank data
SOLUTION:
  - Make sure at least one guild member with bank data is online and has
    the addon installed
  - Try typing /togbank sync to manually request data
  - Verify bank characters have "gbank" in their note and reporting enabled

PROBLEM: Data seems outdated
SOLUTION:
  - Type /togbank sync to request fresh data
  - Bank characters need to open their bank for the addon to scan it
  - Data is automatically synced every 10 minutes when players are online

PROBLEM: A bank reads Behind / Old format on the Bankers tab (a red tab in
         the Inventory window)
SOLUTION:
  - Hover it: it says which it is, and who said so.
  - "Old format" / "predates the current format": that bank character has not
    opened their bank since updating. Ask them to open and close it once.
  - "Behind" / "a newer copy was published": it is already being fetched; it
    goes Current when it lands. If it stays red for more than a few minutes,
    type /togbank sync.
  - "Newer copy unreachable": the only newer copy is on a guildmate whose
    addon is too old to send it. Ask them to update.

PROBLEM: My bank character's own counts look doubled
SOLUTION:
  - Fixed in v1.5.0: the first login on this version repairs it and says so
    in chat. If it persists, /togbank dev sources <banker> <item> shows every
    copy the addon holds for that item - paste that into a bug report.

PROBLEM: /togbank roster shows "----" instead of a number
SOLUTION:
  - The numbering has not reached you yet. It arrives with the next check-in
    from any updated guildmate; /togbank sync asks for it now.
  - If EVERY bank character shows "----", no bank account has logged in or
    scanned on this version yet - nothing can be numbered until one does.

PROBLEM: Delta sync not working
SOLUTION:
  - Make sure other guild members are online with a recent version of the addon
  - Try /togbank sync to manually request fresh data
  - If issues persist, /togbank wipe and re-sync from scratch

PROBLEM: Getting error messages about delta failures
SOLUTION:
  - The addon automatically falls back to full sync on errors
  - Enable debug mode with /togbank debug to see detailed error information
  - For easier debugging, use /togbank debugtab to create a separate chat tab
    for debug output (keeps your General tab clean)
  - Use /togbank debuglog 500 DELTA to export recent delta-related logs for a bug report

PROBLEM: Debug output cluttering my chat
SOLUTION:
  - Use /togbank debugtab to create a dedicated "TOGBank Debug" chat tab
  - All debug messages will go there instead of your main chat
  - This is a one-time setup - the tab persists across sessions
  - Use /togbank debugtabremove to remove the debug tab if needed

PROBLEM: Addon seems to be using too much memory
SOLUTION:
  - Type /togbank compact to clean up old request logs
  - Consider resetting with /togbank reset if database is very large
  - Close and reopen WoW to free up memory

PROBLEM: Bank character's inventory not updating
SOLUTION:
  - Make sure "Enable for <character>" is ticked in the Bank section of the
    addon settings (it is on by default). This is the only setting that stops
    a scan; "Report contributions" is unrelated to sharing.
  - Open the bank and then CLOSE it - the scan runs on close, not on open
  - Type /reload after making configuration changes
  - Verify "gbank" is in the character's public or officer note
  - If the character's own tab is red, hover it: on a shared account played
    from several computers, this one may be behind and will not publish until
    you have opened both the bank and the mailbox on it

PROBLEM: Can't request items
SOLUTION:
  - Make sure you're not the bank character (can't mail to yourself)
  - Check that you have mailbox access
  - Verify the bank character name is spelled correctly

================================================================================
ADVANCED CONFIGURATION
================================================================================

OPTIONS PANEL:
  Press ESC -> Interface -> AddOns -> TOGBankClassic

  Available settings:
  - General: minimap button, hide in combat, chat message volume, "Keep
    syncing in a raid group" (off by default), "Open the Mailbox window
    at a mailbox" (on by default; untick it if you would rather open the
    window yourself with /togbank mailbox or the mail frame's button) and
    "Mailbox window on non-bank characters" (off by default; the window
    opens by itself only on bank characters until you tick this)
  - Appearance: how see-through each window is, "Reset All Windows to
    Solid", "Recenter All Windows" (for a window lost off screen) and
    "Pulsing glow on cancelled requests" (on by default)
  - Bank (bank characters only): "Enable for <character>" - the one switch
    that governs whether this bank is scanned and shared - "Hide soulbound
    items from the guild", and the donation options
  - Debug: persistent logging and the debug categories (tick LOG to watch
    the bank log being written)
  - (OFFICERS ONLY) Officer tab: guild-wide request limits, how long a
    request stays open before it is archived or auto-cancelled, and the help
    notes appended to each window's ? tooltip. Custom cancel reasons are on
    the Requests tab's own Settings sub-tab.

WINDOW TRANSPARENCY:
--------------------------------------
The "Appearance" tab has an opacity slider for every window - Guild Bank,
Mailbox, Inventory, Search, Requests, Donations and the Mail viewer - so you
can fade the ones you leave open and keep the rest solid.

Only the window frame fades. Item icons, stack counts and text stay fully
readable at any setting, and a window you have made transparent still drags
and closes normally. Changes apply immediately to a window that is already
open, and "Reset All Windows to Solid" puts everything back to 100%.

The setting is shared by all your characters, unlike window positions, which
stay per-character.

GUILD REQUEST LIMITS (OFFICERS ONLY):
--------------------------------------
Guild officers can configure maximum request amounts to ensure fair
distribution of limited resources. This feature is only available to
characters with officer note viewing permissions.

To configure request limits:
1. Press ESC -> Interface -> AddOns -> TOGBankClassic
2. Click the "Requests" tab (only visible to officers)
3. Adjust the "Maximum Request Amount" slider (1% - 100%)
4. Changes automatically sync to all guild members

How it works:
- Setting determines the maximum percentage of available inventory that
  can be requested at once
- Example: If set to 50% and there are 100 items available, members can
  request up to 50 items maximum
- Single items (gear, weapons) are protected - members can always request
  at least 1 if available, regardless of percentage
- The setting syncs guild-wide, so all members use the same limits
- Changes take effect immediately for all online guild members

Common use cases:
- Set to 50% during raid prep to share limited consumables fairly
- Set to 33% when multiple members need the same rare materials
- Set to 100% (default) for unrestricted requests
- Adjust dynamically based on guild inventory levels

Request interface behavior:
- Slider maximum is automatically capped at the configured percentage
- Status text shows: "Available: 100 (Max: 50% = 50)"
- Validation message if over limit: "Reduced to max allowed: 50 items
  (50% of 100 available)"

FEATURE FLAGS (for developers):
  Edit Modules/Constants.lua to adjust:
  - FEATURES.DELTA_ENABLED: Enable/disable delta sync globally
  - FEATURES.FORCE_FULL_SYNC: Force full sync (disable delta)
  - PROTOCOL.MIN_DELTA_SIZE_RATIO: Threshold for delta vs full (default 30%)
  - PROTOCOL.DELTA_SUPPORT_THRESHOLD: Required adoption % (default 50%)

================================================================================
SUPPORT & FEEDBACK
================================================================================

Found a bug? Have a suggestion? We'd love to hear from you!

- Report issues on CurseForge: https://www.curseforge.com/wow/addons/togbankclassic
- Join our Discord community (if available)
- Contact the addon authors in-game

When reporting bugs, please include:
1. Your TOGBankClassic version (/togbank version)
2. Steps to reproduce the problem
3. Any error messages (enable /togbank debug for details)
4. Your WoW client version

================================================================================
CHANGELOG HIGHLIGHTS
================================================================================

Version 1.5.0:
--------------
NEW FEATURES:
- The addon is "TOG Bank" on screen; every window is titled that way
- One Guild Bank window (minimap button): every bank's items as one sortable
  list with filters across the top, plus Bankers, Requests and Log tabs; it
  remembers its position, size and tab. The old window is /togbank legacy
- A Mailbox window: the inbox as rows, the game's own click-to-take, Take
  Needed for what open orders are short of, an envelope to return a mail
- Bank characters can hide items from the guild (right-click), or every
  soulbound item at once (Bank settings)
- A bank log: deposits, withdrawals, money and every request event, with who
  was on each side; handed to TOGTools for the long history
- A bank character is told when their update has reached the guild (red /
  amber / green line in every window's bottom bar), and warned on logout
- One search box on the Requests tab; cancelled requests glow so the reason
  is found; a request from an out-of-date guildmate shows their version
- "Keep syncing in a raid group" setting; "Recenter All Windows" button

IMPROVEMENTS:
- Several orders for one person go in one mail, splits included; Fulfill
  Oldest works the whole queue; collecting at the bank swaps unneeded stacks
  in when the bags are full
- Catching up on a bank sends only what changed, fingerprint-checked
- Saved data roughly halved: the old copy of every bank is gone
- Completed and cancelled requests kept 14 days instead of 30
- Every window shares the same title, status bar, help ? and scrollbar

BUG FIXES:
- A bank character's own counts could show doubled
- Banks read as out of date when nothing newer existed; guildmates on the
  old version blocked transfer slots; a bank could stay out of date for days
- Items with a random suffix showed only the base name; requests could show
  "Item 7969"; "[WHISPER-SPAM-FIX]" chat lines; a Lua error in mixed guilds
- Shared accounts: a bank played from two computers no longer publishes a
  stale vault over the newer copy

COMPATIBILITY: bank contents no longer travel between v1.5.0 and older
clients in either direction. Everyone should update; bank characters open and
close their bank once afterwards.

Version 1.4.1:
--------------
NEW FEATURES:
- The Fulfill button collects from the bank as well as attaching to mail
- Every bank character has a permanent four-digit number, assigned by the
  addon and identical on every client (/togbank roster)
- A bank character's fresh scan reaches everyone online within seconds
- Bank tabs coloured by whether your copy is current; hover a red tab for why

IMPROVEMENTS:
- Guild check-ins about a fifth of their former size; offers a single message
- The handshake between two players rides a fast lane separate from bulk data
- Downloads from different guildmates run at the same time
- Nobody is refused at capacity: you are told your place in the queue

BUG FIXES:
- Banks stayed red after their data had arrived, or could never be brought up
  to date because their contents happened to match an older copy
- Late offers were thrown away; requests went guild-wide for banks nobody had
  newer copies of; a leaked send slot made bank characters "busy" to everyone
- The item tooltip listed characters who are no longer bank characters
- Another addon could overwrite this addon's debug category list
- Help text said sharing ran every 3 minutes; it is 10, and after every scan

COMPATIBILITY: v1.4.0 clients cannot read the new check-in or offer messages
and stop hearing offers until they update. Open and close each bank once.

Version 1.4.0:
--------------
NEW FEATURES:
- Bank contents travel as compact numbers rather than item links (85% less)
- A bank's version stamp is written once by the bank character and carried
  unchanged by everyone else
- Guild roster and online tracking moved to LibGuildRoster

COMPATIBILITY: not backwards compatible with earlier versions - see HOW
SYNCING WORKS above.

Version 1.3.0:
--------------
NEW FEATURES:
- Burning Crusade support: a separate TBC build is now published alongside
  Classic Era, with identical features and commands
- Classic Era build updated to the current game patch, so it is no longer
  flagged "out of date" in the AddOns list

Version 0.8.0:
--------------
NEW FEATURES:
- Link-less delta optimization for additional bandwidth savings
- Persistent debug logging system with export capability
- Dedicated debug chat tab support
- Enhanced delta error tracking and reporting

NEW COMMANDS:
- /togbank clearhistory - Clear delta chain history
- /togbank debuglog [N] [filter] - Export debug logs
- /togbank debuglogclear - Clear persistent logs
- /togbank debuglogsave - Save logs to disk
- /togbank debuglogstats - View log statistics
- /togbank debugtabremove - Remove debug chat tab
- /togbank clear-delta-errors - Clear all recorded delta errors
- /togbank deltaerrors - View recent delta failures
- /togbank deltahistory - View delta chain history
- /togbank forcedelta [on|off] - Force delta mode
- /togbank perfstats - Performance metrics
- /togbank persistcheck - Check persistence state
- /togbank test - Run automated tests

IMPROVEMENTS:
- Delta packets no longer include item links (rebuilt on receive)
- Better validation for link-less delta items
- Fixed mail items array format handling
- Converted debug print statements to proper logging system
- Reorganized command help alphabetically
- Enhanced debug output with category filtering

BUG FIXES:
- Fixed delta validation rejecting valid link-less items
- Fixed mail item multiplication in UI
- Fixed 6 locations treating mail.items as hash instead of array
- Fixed command help missing several commands
- Removed duplicate forcefull command
- Cleaned up trailing whitespace in all code files

Version 0.7.0:
--------------
NEW FEATURES:
- Delta sync protocol for 90-99% bandwidth reduction
- Intelligent protocol version negotiation
- Automatic snapshot management and error recovery
- Comprehensive bandwidth and performance metrics
- 5 new commands for monitoring and management

NEW COMMANDS:
NOTE: these five moved under the "dev" prefix in a later release, because they are
diagnostic tools rather than everyday commands. They are listed here in their
current form; "/togbank dev help" lists everything available.
- /togbank dev deltastats - View sync statistics
- /togbank dev protocol - Check protocol adoption
- /togbank dev clearsnapshots - Clear delta cache (removed in v1.5.0; it had nothing left to clear)
- /togbank dev forcefull - Toggle full sync mode
- /togbank dev resetmetrics - Reset statistics

IMPROVEMENTS:
- Dramatically reduced network traffic for inventory updates
- Better error handling with automatic fallback
- Enhanced debug output with performance metrics
- Backwards compatible with v0.6.8 clients

For complete changelog, see CHANGELOG.md

================================================================================
CREDITS
================================================================================

Original Authors:
- Dominion-Myzrael
- GrumpyPlayers (also known as <SG>Soul)
- Lothsahn
- Huntmehuntme-Myzrael

Special thanks to:
- All contributors and testers
- The WoW Classic community
- Users who provided feedback and suggestions

Libraries Used:

Installed automatically alongside TOGBankClassic (required):
- Ace3 framework (AceAddon, AceComm, AceConfig, AceDB, AceEvent, AceGUI)
- VersionCheck-1.0 - tells you when a newer version is available
- LibGuildRoster - guild roster and online/offline tracking (v1.4.0+)
- AceCommQueue-1.0 - orders outgoing addon traffic so messages arrive intact
    (bundled inside the addon before v1.4.0; now a separate addon so it stays
     current instead of quietly falling behind its own releases)
- ItemDB - the offline item database bank contents are named from (v1.4.0+)
- DeltaSync - shared sync library (v1.4.0+)
- LibAceGUIWidgets - the shared search box and window widgets (v1.5.0+)

Bundled with the addon:
- LibDataBroker-1.1
- LibDBIcon-1.0
- ChatThrottleLib (ships with Ace3's AceComm)

================================================================================
LICENSE
================================================================================

TOGBankClassic is released under the GNU General Public License v3.0
See LICENSE file for full license text.

================================================================================

Thank you for using TOGBankClassic!

For the latest updates and information, visit:
https://www.curseforge.com/wow/addons/togbankclassic

================================================================================

