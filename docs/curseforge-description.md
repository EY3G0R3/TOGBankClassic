# TOGBankClassic - Guild Bank Management for Classic Era

Are you tired of logging into multiple bank alts to find items? Does your guild rely on character banks instead of the guild vault? TOGBankClassic is the solution!

TOGBankClassic is a powerful, feature-rich addon that transforms how your guild manages inventory across multiple bank characters. View, search, and request items from all your guild bank alts without ever logging out—all in one convenient interface.

## Project History

TOGBankClassic is The Old Gods guild's enhanced fork of GBankClassic-Revived, bringing significant improvements to guild bank management. Our team added extensive new functionality including:

• Mailbox inventory tracking and integration
• One-click item requests directly from search results
• Full request management system with fulfillment tracking  
• Smart item highlighting for bankers (Bagnon integration)
• Automated order fulfillment with intelligent stack splitting
• Auto-marking of fulfilled requests when mail is sent
• Enhanced debug logging and performance metrics
• Delta-based sync protocol (90-99% bandwidth reduction)
• Advanced P2P communication for faster data population
• Officer-configurable percentage-based request limits

We're grateful to the GBankClassic-Revived team for the foundation, and we continue to build on their excellent work with features tailored for active guild bank management in Classic Era.

## Core Features

### Unified Inventory Management

• One-Click Access: View the complete inventory of all guild bank characters in a single window
• No Alt-Hopping: Never log out to check what's in stock—see everything at a glance
• Real-Time Updates: Inventory automatically syncs across all guild members using the addon
• Mail Integration: Track items in transit—see what's in the mailbox as part of total inventory

### Powerful Search System

• Guild-Wide Search: Search across all bank characters simultaneously—find any item instantly
• Live Filtering: Results update as you type, showing exact quantities and locations
• Click to Request: Click any search result to open a request dialog with smart quantity suggestions
• Availability Info: See max requestable amounts based on officer-configured limits

### Smart Request System

• In-Game Requests: Guild members request items directly through the addon—no whispers needed
• Request Tracking: View all pending, fulfilled, and completed orders in the Requests window
• Priority System: Mark requests as Rush, High, Normal, or Low priority for better organization
• Officer Controls: Officers can configure guild-wide request percentage limits (1-100% of inventory)

### Automated Order Fulfillment

• One-Click Fulfill: Bankers click "Fulfill" button—addon automatically attaches items to mail
• Smart Stack Splitting: Automatically splits oversized stacks with confirmation dialogs

- Example: Request for 2 Felcloth from a 5-stack? Addon prompts to split precisely 2 items
- Complex requests (e.g., 175 Runecloth from mixed stacks) handled automatically

• Optimal Stack Selection: Intelligent bin-packing algorithm selects best stack combinations
• Visual Indicators: Button icons change to show split needed vs. ready to mail

### Blazing-Fast Synchronization

• Delta Sync Protocol: Only syncs what changed—achieves 90-99% bandwidth reduction
• Link-Less Optimization: Removes redundant item links for additional bandwidth savings (v0.8.0+)
• Pull-Based Handshake: Clients request only the data they need, when they need it
• Compact Request Protocol: Request index and records sync in a compact positional format — ~60% less bandwidth than the previous key-value format
• Event-Sourced Requests: Append-only request log prevents conflicts and data loss
• Offline Resilience: Players who were offline automatically catch up when they log in

## Advanced Features

### For Guild Members

• Minimap Button: Quick access to inventory—toggle visibility in options
• Bagnon Integration: Automatic item highlighting in bags when fulfilling orders (requires Bagnon addon)
• Request History: View your past requests with fulfillment status
• Fair Distribution: Officer-configured limits ensure equitable access to guild resources
• Mute Warnings: Checkbox to hide low-priority warnings for cleaner chat

### For Bank Alts

• Automatic Detection: Add "gbank" to Public Note or Officer Note—addon handles the rest
• Auto-Scan: Configure to scan bank/bags/mail automatically when opened
• Mail Fulfillment: Receive requests, click Fulfill, send mail—streamlined 3-step process
• Donation Tracking: Optional feature to accept and track donations from guild members

### For Officers

• Request Limits: Set max request percentage (e.g., 50% = members can request up to half of available stock)
• Protects Unique Items: Always allows requesting at least 1 if available (gear, BoE epics, etc.)
• Syncs Guild-Wide: Limit setting automatically syncs to all guild members
• Debug Tools: Access advanced diagnostics via slash commands for troubleshooting

### Developer & Performance

• Persistent Debug Logging: 50,000-entry buffer with 7-day retention and category filtering
• Performance Metrics: Built-in telemetry tracks memory usage and bandwidth consumption
• Version Checking: Automatic notifications when new versions are available (VersionCheck-1.0)
• Ace3 Framework: Built on industry-standard Ace3 libraries for reliability and compatibility

## How It Works

### Setup (One-Time)

1. Bank Characters: Add "gbank" to character's Public Note or Officer Note
2. Enable Reporting: In AddOns settings, enable "Report bank contents" and "Scan bank on open"
3. Scan Inventory: Open your bank/bags/mail—addon scans and shares with guild
4. Done! Inventory is now visible to all guild members using TOGBankClassic

### Daily Usage

**For Guild Members:**

1. Open TOGBankClassic (minimap button or /togbank show)
2. Click "Search" → type item name (e.g., "Felcloth")
3. Click result → dialog shows available quantity
4. Enter amount → click "Send Request"
5. Wait for mail notification—it's that easy!

**For Bank Alts:**

1. Open TOGBankClassic → click "Requests"
2. See all pending requests with quantities
3. Click "Fulfill" on any request
4. Addon attaches items (auto-splits if needed)
5. Type recipient name → send mail → done!

## Why Choose TOGBankClassic?

### Efficiency

• Time Savings: What once took 10+ minutes of alt-hopping now takes 30 seconds
• Bandwidth Friendly: Delta sync uses 1-10% of bandwidth compared to full snapshots
• Zero Lag: Smart throttling and caching prevents performance issues

### Reliability

• Event-Sourced Architecture: Request log prevents data corruption and conflicts
• Conflict-Free Merging: Multiple players can modify requests simultaneously without issues
• Data Recovery: Full history allows reconstruction if SavedVariables get corrupted

### User Experience

• Intuitive Interface: Clean tabbed UI with Search, Requests, and Inventory views
• Smart Defaults: Works out-of-box with sensible settings—configure only if needed
• Error Handling: Graceful failures with informative messages (never crashes silently)

### Active Development

• Regular Updates: Frequent bug fixes and feature additions
• Community-Driven: Features requested by actual guild bank managers
• Well-Documented: Extensive in-code documentation and design docs

## Slash Commands

### Basic Commands

• /togbank or /togbank show - Open main inventory window
• /togbank sync - Manually trigger full guild sync
• /togbank share - Broadcast your inventory/requests to guild
• /togbank wipe - Reset your local database (keeps character data)
• /togbank wipeall - Reset entire database (fresh start)
• /togbank wipeframes - Reset window positions to defaults

### Debug Commands (Advanced)

• /togbank debug - Toggle debug output in chat
• /togbank hashdebug - Show banker hash freshness (diagnose sync issues)
• /togbank deltastats - Display P2P synchronization telemetry
• /togbank perfmetrics - Show memory usage and performance stats

## Configuration

### Access Options

• Press ESC → Interface → AddOns → TOGBankClassic
• OR: /togbank options

### Key Settings

• Bank Section: Enable reporting, auto-scan on bank open, mail scan settings
• Request Section: Configure request limits, priority display, mute warnings
• UI Section: Minimap button visibility, window opacity
• Debug Section: Enable persistent logging, toggle debug categories

## Dependencies & Compatibility

### Required

• Ace3: Core framework (auto-installed via CurseForge)
• VersionCheck-1.0: Update notifications (auto-installed)

### Optional

• Bagnon: Enhanced bag highlighting for order fulfillment

### Compatibility

• World of Warcraft Classic Era (Interface 11508+)
• Tested with major bag addons (Bagnon, AdiBags, ArkInventory)
• Works alongside other guild management addons

## Bug Reports & Feature Requests

Found a bug or have a suggestion?
• CurseForge Issues: [curseforge.com/wow/addons/togbankclassic/issues](https://www.curseforge.com/wow/addons/togbankclassic/issues)
• GitHub: [github.com/EY3G0R3/TOGBankClassic](https://github.com/EY3G0R3/TOGBankClassic)
• In-Game: Use /togbank debug to capture logs, then export from SavedVariables

## Credits

Developed by:
• Dominion-Myzrael - Lead Developer
• GrumpyPlayers (SG Soul) - Core Systems
• Lothsahn - Architecture & Optimization
• Huntmehuntme-Myzrael - Testing & QA
• Pimptasty - UI/UX Design

**Special Thanks:**
• The Old Gods guild community for extensive beta testing
• GBankClassic-Revived team for the original foundation
• Bagnon team for their excellent bag addon and integration support
• Ace3 library maintainers for the excellent framework
• WoW Classic community for feedback and support

## License

TOGBankClassic is open-source software. See LICENSE file for details.

## Perfect For

• Raiding Guilds: Manage consumables, flasks, resistance gear across multiple bank alts  
• Crafting Guilds: Track raw materials and provide easy access for crafters  
• PvP Guilds: Distribute consumables and gear to members efficiently  
• Leveling Guilds: Share leveling gear and consumables with new members  
• Classic Era Servers: No guild vault? No problem—this addon is your solution

## Tips & Best Practices

1. Designate 2-3 bank alts: Spread items across multiple characters for better organization
2. Use Officer Notes: Keep Public Notes clean by adding "gbank" to Officer Notes instead
3. Regular Scans: Bank alts should scan inventory daily to keep data fresh
4. Request Limits: Set limits to 50-75% to prevent single members from depleting stocks
5. Priority System: Train members to use Normal priority unless truly urgent
6. Mail Monitoring: Enable mail scanning to track items in transit

## Recent Updates

v0.9.14 (Latest)
• Two new inventory sort modes — the sort button now cycles through A-Z, By Type, By Rarity (epic first), and By Level (highest first)

v0.9.13
• Fixed request index flood on large guilds — guilds with 500+ requests could trigger a storm of duplicate index transmissions when multiple peers responded simultaneously; peers now coordinate so only one sends at a time, with the others standing down
• "Syncing requests with guild…" and "Broadcasted hash for \<alt\>" chat messages now respect the Mute Sync Progress Messages setting

v0.9.12
• Stale banker tabs — banker tabs turn red with a tooltip when guild members have a newer hash for that alt, so you know at a glance when displayed inventory may be out of date
• /togbank versioncheck — broadcast a version check to all guild members and see who is running which version (works with all addon versions via VersionCheck-1.0)
• Fixed quality border colours on weapons and armour — gear now shows the correct rarity colour (green/blue/purple) rather than always white
• Fixed mail item tooltips showing blank names
• Performance: NormalizeRequestList now skips its full rebuild when nothing has changed

v0.9.10
• Request sync now uses ~60% less bandwidth — a new compact positional wire format replaces the verbose key-value protocol for both the requests index and individual records; guilds with 500+ requests will see the biggest improvement on initial sync and after being offline

v0.9.8
• Fixed expired requests never being pruned — fulfilled/cancelled requests from 30+ days ago were accumulating indefinitely; pruning now runs automatically every ~3 minutes
• Network status bar labels renamed: Tx: (outgoing), Rx: (P2P fetches), Bcast: (broadcast queue) — clearer than the old send:/P2P:/q: labels
• Status bar now drops the right section first when the window is narrow, keeping the more useful left + centre visible longer

v0.9.6
• Request sync throttle overhaul: deduplicating response drain, coalesced index responses, chunked 20-ID sending — eliminates multi-minute CTL backlogs on large guilds
• Network status bar (opt-in, Options -> General): live CTL activity with left/centre/right alignment; hides sections automatically when window is narrow
• /togbank netq: new command showing full CTL queue breakdown by message type and recipient
• Request window now shows total count alongside filtered count (e.g. "3 / 47")
• Fixed self-query loop where a lone banker would whisper themselves on login

v0.9.5
• Request status colours: fulfilled = green, cancelled = red
• Item sort toggle: A-Z or By Type in inventory view
• Fixed request sync stalling on login for players offline 1+ days
• Fixed options window crash on open
• Fixed /togbank sync being silently blocked by cooldown
• Fixed /togbank hello crash on unpackaged builds
• Fixed slot counts showing 0/0 for non-banker characters
• Removed broken /togbank requestlog command (superseded by Requests UI)

v0.9.0
• Event-sourced request log with merge-based conflict resolution
• Request fulfillment tracking with partial fulfillment support
• Officer permission controls for request management
• P2P session manager for faster data distribution

---

Download TOGBankClassic today and revolutionize your guild's bank management!

No more alt-hopping. No more whisper spam. Just efficient, organized guild banking.
