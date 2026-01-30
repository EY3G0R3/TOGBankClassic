================================================================================
TOGBankClassic - Guild Bank Inventory Management for WoW Classic Era
================================================================================

Version: 0.8.0
Authors: Dominion-Myzrael, GrumpyPlayers (SG Soul), Lothsahn, Huntmehuntme
Website: https://www.curseforge.com/wow/addons/togbankclassic

================================================================================
WHAT IS TOGBANKCLASSIC?
================================================================================

TOGBankClassic is a powerful addon that allows you to view and manage the
combined inventory of multiple guild bank characters without logging into
each one. Perfect for guilds that use character banks instead of (or in
addition to) the guild vault system.

KEY FEATURES:
- View all guild bank inventories in one convenient interface
- Search across all bank characters simultaneously
- Request items from guild banks via in-game mail
- Automatic synchronization with other guild members using the addon
- Delta sync protocol for 90-99% bandwidth reduction
- Link-less delta optimization for additional bandwidth savings (NEW in v0.8.0!)
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

3. Select "World of Warcraft Classic Era" from the game version dropdown

4. Go to the "Get More Addons" section

5. Search for "TOGBankClassic"

6. Click "Install" on the TOGBankClassic addon

7. Launch World of Warcraft Classic Era through the CurseForge App
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
   World of Warcraft\_classic_era_\Interface\AddOns\

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
7. Enable "Report bank contents" and "Scan bank on open"
8. Open your bank to perform the initial scan
9. The addon will now automatically share this character's inventory!

FOR REGULAR GUILD MEMBERS:
---------------------------
1. Just install the addon - no configuration needed!
2. Type /togbank to open the guild bank inventory interface
3. Type /togbank sync to manually request latest data from bank characters
4. The addon automatically syncs every 10 minutes

================================================================================
BASIC USAGE
================================================================================

OPENING THE INTERFACE:
  /togbank
    Opens the main TOGBankClassic inventory window showing all items
    across all guild bank characters.

SEARCHING FOR ITEMS:
  Use the search box in the main interface to find items across all banks.
  Click on an item to see which bank character has it and request it.

REQUESTING ITEMS:
  Click "Request" next to an item to automatically send a mail request
  to the bank character. They'll see your request the next time they log in.

MANUAL SYNC:
  /togbank sync
    Manually requests the latest inventory data from all online guild
    members who have the addon installed.

SHARING YOUR DATA:
  /togbank share
    Manually shares your bank character's inventory with other online
    guild members. This happens automatically every 3 minutes.

    IMPORTANT: You must have your bank open and wait ~1 second for the
    scan to complete before using this command. The addon needs time to
    read all items from your bank bags. For best results, open the bank,
    wait a moment, then run /togbank share.

================================================================================
COMMAND REFERENCE
================================================================================

BASIC COMMANDS:
---------------
/togbank
  Opens the TOGBankClassic inventory interface

/togbank help
  Displays help information and command list

/togbank version
  Shows your current TOGBankClassic version

/togbank sync
  Manually sync to receive latest data from online users
  (Automatic sync happens every 10 minutes)

/togbank share
  Manually share your guild bank contents with online users
  (Automatic sharing happens every 3 minutes)

  NOTE: Bank must be open and scanned before sharing. Open your bank,
  wait ~1 second for items to load, then run this command.

/togbank reset
  Resets your TOGBankClassic database (clears all stored data)


EXPERT COMMANDS:
----------------
These commands are for advanced users and guild officers. Commands are
listed alphabetically for easy reference.

/togbank clearhistory
  Clears delta chain history (removes saved deltas)

/togbank clearsnapshots
  Clears all delta snapshots (forces next sync to be full)

/togbank compact
  Manually runs database compaction to prune old requests and log entries

/togbank debuglog [N] [filter]
  Exports last N debug log entries (default 500), optionally filtered by keyword
  Example: /togbank debuglog 100 MAIL
  Example: /togbank debuglog 1000

/togbank debuglogclear
  Clears all persistent debug log entries

/togbank debuglogsave
  Manually saves debug log to SavedVariables (normally done on logout)

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

/togbank deltaerrors
  Shows recent delta sync errors and failure counts

/togbank deltahistory
  Shows stored delta chain history for offline recovery

/togbank deltastats
  Shows delta sync statistics including:
  - Bandwidth usage (delta vs full syncs)
  - Estimated bandwidth saved
  - Success rates and operation counts
  - Average performance metrics

/togbank forcedelta [on|off]
  Forces delta sync mode (bypasses thresholds) for testing
  Use 'on' to always use delta, 'off' to restore normal behavior

/togbank forcefull [on|off]
  Forces full sync mode (disables delta) for testing
  Use 'on' to disable delta, 'off' to restore normal behavior

/togbank hello
  Shows which guild members are online with the addon and what data they have
  (Requires compatible WeakAura to display deserialized data)

/togbank perfstats
  Shows performance metrics for current session

/togbank persistcheck
  Checks current request persistence state (for debugging SYNC-001)

/togbank protocol
  Displays protocol version distribution across guild members:
  - Shows online member protocol versions (v1 vs v2)
  - Displays delta sync adoption percentage
  - Lists recently seen members with their protocol versions

/togbank requestlog [N|all]
  Shows the item request log (optionally limited to N entries)
  Example: /togbank requestlog 10

/togbank resetmetrics
  Resets all delta sync statistics to zero

/togbank roster
  Guild officers can use this to share updated roster data with the guild
  (Requires officer note viewing permissions)

/togbank test [test-name|all|help]
  Runs automated delta sync tests
  Use 'help' to see available test options

/togbank versions
  Displays addon versions of all online guild members

/togbank wipe
  Resets your own TOGBankClassic database

/togbank wipeall
  (OFFICER ONLY) Resets database for all online guild members
  WARNING: This affects everyone - use with caution!


DEBUG COMMANDS:
---------------
/togbank debug
  Toggles debug mode on/off for troubleshooting
  Shows detailed information about addon operations
  Setting persists across reloads and is saved to your addon settings
  TIP: Use /togbank debugtab first to create a dedicated debug chat tab

================================================================================
DELTA SYNC FEATURE (v0.7.0+)
================================================================================

TOGBankClassic v0.7.0+ includes an intelligent delta sync protocol that
dramatically reduces bandwidth usage by only transmitting changed data instead
of complete inventories. Version 0.8.0 adds link-less optimization for even
greater bandwidth savings.

HOW IT WORKS:
-------------
When guild bank characters update their inventory, the addon automatically:
1. Detects what items have changed since the last sync
2. Strips item links from delta packets (links rebuilt on receive-side)
3. Calculates if sending just the changes is more efficient
4. Uses delta sync if it saves more than 70% bandwidth
5. Falls back to full sync if changes are too large
6. Automatically handles errors and version mismatches

BENEFITS:
---------
- 90-99% reduction in bandwidth for typical updates
- Link-less optimization further reduces delta packet size
- Faster sync times and less network traffic
- Fully automatic - no configuration required
- Backwards compatible with older clients
- Robust error handling with automatic fallback
- Persistent debug logging for troubleshooting

MONITORING DELTA SYNC:
----------------------
Use /togbank deltastats to see:
- How much bandwidth you've saved
- Success rate of delta operations
- Average performance metrics

Use /togbank protocol to check:
- How many guild members support delta sync
- Whether delta sync is enabled (requires 50% guild adoption)

Use /togbank deltaerrors to see:
- Recent delta sync failures
- Error types (UNAUTHORIZED, VALIDATION_FAILED, etc.)
- Failure counts for troubleshooting

Use /togbank deltahistory to see:
- Stored delta chain for offline recovery
- Delta sequence numbers and timestamps

COMPATIBILITY:
--------------
- v0.7.0+ clients can send and receive delta updates
- v0.6.8 and older clients receive full syncs (no delta support)
- Mixed guild scenarios work seamlessly
- Delta sync automatically enables when 50%+ of online guild uses v0.7.0+

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

PROBLEM: Delta sync not working
SOLUTION:
  - Check /togbank protocol to see guild adoption percentage
  - Delta sync requires 50%+ of online guild to use v0.7.0+
  - Use /togbank forcefull on to toggle full sync mode if needed
  - Check /togbank deltastats to see if delta operations are failing

PROBLEM: Getting error messages about delta failures
SOLUTION:
  - The addon automatically falls back to full sync on errors
  - Use /togbank deltaerrors to see recent failure details
  - If errors persist, try /togbank clearsnapshots to clear cached data
  - Use /togbank resetmetrics to reset statistics
  - Enable debug mode with /togbank debug to see detailed error information
  - For easier debugging, use /togbank debugtab to create a separate chat tab
    for debug output (keeps your General tab clean)
  - Use /togbank debuglog 500 DELTA to export recent delta-related logs

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
  - Make sure "Report bank contents" is enabled in addon settings
  - Make sure "Scan bank on open" is enabled
  - Open the bank to trigger a new scan
  - Type /reload after making configuration changes
  - Verify "gbank" is in the character's public or officer note

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
  - Enable/disable reporting for specific characters
  - Enable/disable automatic bank scanning
  - Configure minimap button position
  - Adjust output verbosity

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
- /togbank deltastats - View sync statistics
- /togbank protocol - Check protocol adoption
- /togbank clearsnapshots - Clear delta cache
- /togbank forcefull - Toggle full sync mode
- /togbank resetmetrics - Reset statistics

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
- Ace3 framework (AceAddon, AceComm, AceConfig, AceDB, AceEvent, AceGUI)
- LibDataBroker-1.1
- LibDBIcon-1.0
- ChatThrottleLib

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

