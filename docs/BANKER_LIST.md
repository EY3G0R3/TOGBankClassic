# BANKER-LIST-001: an officer-owned banker list

Status: **SHELVED, not planned** (2026-09-25). No code was written. The operator, the same day,
after reading this design: *"i'm having second thoughts, right now any client without sync or data
gets a banker list, it might be good to just leave it alone"*. The `gbank` note rule stays. Kept as
the record of what was considered, in case it is asked for again.

## Why

Today a guild member is a bank character when their public or officer note contains `gbank`. Anyone
who can edit their own public note can make themselves a banker. The operator, 2026-09-25:

> why can't we have it as an officer setting, who is a banker and who isn't, that way some yahoo
> doesn't just input the gbank tag and show up ... using the guildroster roster and an
> autocomplete search bar from the widgets library to build the table

And on adoption:

> we will need a mechanism, a one time import to build out the officer list from current notes,
> then stop accepting them somehow. make it easier for adoption

## The rule, in one paragraph

Each guild has a list of its bank characters, written only by its officers. **Until an officer of
that guild first saves or imports the list, the `gbank` note rule decides for that guild, exactly as
today.** From that save on, the list alone decides for that guild and notes are ignored. The switch
is per guild: a sister guild still on notes keeps its note bankers even after the home guild has a
list.

## Where banker identity is decided today

Every site below is replaced by one function, `Guild:BankerEntry(norm)`, which returns
`isBank, viewOnly, stores` from the list when that character's guild has one, and from the notes
otherwise. Line numbers are from the 2026-09-25 working tree.

| Site | File | What it reads |
| --- | --- | --- |
| `GetBanks` fallback scan | `Modules/Guild.lua:637-638` | `gbank` in public/officer note |
| `_SisterBankers` | `Modules/Guild.lua:662-681` | `gbank` in a sister member's note |
| `RebuildBankerRoster` | `Modules/Guild.lua:695-704` | home notes, sets `isBank` / `viewOnly` |
| `IsViewOnlyBank` fallback | `Modules/Guild.lua:1204` | `noteIsViewOnly` |
| `BankerStores` | `Modules/Guild.lua:1221-1244` | note text with the markers stripped |
| `SenderHasGbankNote` | `Modules/Guild.lua:3907-3933` | `isBank`, else a `gbank` roster scan |
| `_RefreshFromRosterLib` | `Modules/Guild.lua:4108-4127` | library's `publicNote` / `officerNote` |
| `_AddSisterMembers` | `Modules/Guild.lua:4166-4178` | sister `m.note` |
| `RefreshOnlineCache` legacy path | `Modules/Guild.lua:4294-4309` | `GetGuildRosterInfo` notes |

`VIEW_ONLY_MARKERS` (`Modules/Guild.lua:601`) and the note parsing stay, used only by the note path
and by the import.

## Data

Per guild, in `Info.settings` (so it rides the existing guild-settings sync):

- `bankerList[Name-Realm] = { stores = "<text>", viewOnly = true|false }`, or `false` for a removed
  entry. The `false` keeps the removal's stamp, so an older add cannot bring it back.
- `bankerListStamps[Name-Realm] = serverTime`, one stamp per entry, written as
  `max(GetServerTime(), old + 1)`. This is the `bankerOwnerStamps` pattern (BANKER-OWNER-001), and
  the merge is the same: the newer stamp wins per entry.
- `bankerListActive[guildKey] = serverTime`: the moment that guild's list took over. Present means
  "that guild uses its list". Never cleared by the UI; see "Going back to notes".

Limits as for owners: 100 entries, `stores` capped at 40 characters, sanitised on receive.

`stores` replaces the note text `BankerStores` shows today ("what they store"). `viewOnly` replaces
the note markers (VIEWBANK-001).

## Writing

- One writer, `Guild:SetBankerListEntry(norm, entry)`, plus `Guild:ImportBankerListFromNotes()`.
  Both refuse unless the player is an officer of the character's own guild, then stamp and call
  `BroadcastSettings("ALERT")`.
- The first successful write for a guild also sets `bankerListActive[guildKey]`.

## Import (the adoption step)

**Import from notes** does this once, for the officer's own guild only:

1. Read the guild's current roster from LibGuildRoster (`GetAllMembers` / `GetMember`, public and
   officer notes).
2. Each member whose note has `gbank` becomes an entry. `viewOnly` comes from the view-only markers.
   `stores` is the note with the markers stripped: the same text the Bankers tab shows today.
3. Stamp every entry, set `bankerListActive`, broadcast.

The officer sees the imported list before anything is saved and can remove anyone first. After the
import, adding `gbank` to a note does nothing for that guild.

A sister guild imports its own list from its own client. The home guild cannot import for it, and
the home guild's list cannot contain the sister guild's characters.

## Syncing

- **Guild-wide:** `bankerList`, `bankerListStamps` and `bankerListActive` are new `SettingsFields`
  (`Modules/Guild.lua:3614`). They go in the canon (`CanonOfSettingsFields`, `:3296`) except the
  stamps, as for `bankerOwnerStamps`. `ApplyRemoteSettings` gets an `adopt` block that merges per
  entry.
- **Sister guilds:** as for owners (XGUILD-OWNERS-001 / XGUILD-SETTINGS-001). A sister sender's
  entries are accepted only for characters of the sender's own guild. The whisper answer
  (`SendBankerOwnersTo`, `:3090`) also carries the list, minus the receiver's own guild's entries
  (the F4 rule).

## Who may write, on receive

This is the one part the note rule never needed. Today `SettingsSenderAuthorized` (`:3328`) and
`ApplyRemoteSettings` (`:3760`) accept settings from a sender with a `gbank` note, which is exactly
the check the list exists to remove.

- **Home guild:** accept a list change only when `Guild:SenderIsOfficer(sender)` is true
  (`Modules/Guild.lua:4918`). It already judges any home member: either the cache-time threshold, or
  the `officerRankFloor` the GM's client reads from the guild's rank permissions and publishes
  (SETTINGS-003, `:3514-3547`). Until the GM has logged in on a build that publishes the floor, only
  the cache-time threshold applies, which is the same KNOWN COST SETTINGS-003 already carries.
- **Sister guilds:** `SenderIsOfficer` cannot judge a sister guild's ranks (it requires
  `guildKey == nil`), and LibGuildRoster's sister roster carries a rank name, not a rank index. So a
  sister guild's list is accepted from any member of that guild, limited to that guild's own
  characters, exactly as owners are today. KNOWN COST: a member of a sister guild could relay a list
  their officers never wrote. Their own guild would override it on the next officer write, and it
  cannot touch the receiving guild's own bankers.

## UI

A **Bankers** section in the Officer settings group (`Modules/Options.lua`, next to Sister guilds at
`:904`). It is shown only to officers.

- **Status line:** "Using guild notes (gbank)" until the list is active. After that: "Using the
  banker list since <date>".
- **Import from notes** button, shown only while the guild is still on notes.
- **The table:** name, what they store (editable), view-only (checkbox), remove.
- **Add:** a search box over the guild's roster. LibAceGUIWidgets has no free-text autocomplete
  widget. Its `CreateDropdownBox` with `search = true` (`LibAceGUIWidgets-1.0.lua:1934`) calls
  `items(query)` on each keystroke and picks from a list, which suits "pick a guild member" better
  than free text. The roster source is `Browse:OwnerNameSource` (`Modules/UI/Browse.lua:1668`),
  limited to the home guild.

The Bankers tab and tooltips keep reading `isBank` / `viewOnly` / `stores` as today. Only where
those values come from changes.

## Mixed versions (KNOWN COST)

Clients from v1.6.1 and earlier do not know the list and keep following notes. Until the whole
guild has updated, officers should leave the `gbank` notes in place, or older clients lose their
bankers. The player notes must say this. Once everyone is on the list-aware version, officers can
clear the notes. For a list-aware client, a note left behind does nothing.

## Going back to notes

Not offered in the UI. An officer who wants notes back would need a "Use guild notes again" button
that clears `bankerListActive` with a newer stamp. Left out until someone asks.

## Tests (offline)

- The note rule is unchanged for a guild with no list, including sister guilds.
- The import seeds exactly the note bankers, with view-only and stores text, then ignores a new
  `gbank` note.
- Per-entry merge: newer stamp wins, a removal survives an older add, and an old client without
  stamps seeds an empty list only.
- A sister sender can set only its own guild's entries. F4: the answer to a sister guild never
  carries that guild's own entries back to it.
- A non-officer sender's list change is refused on receive.
- End to end on the fleet (`env_fleet`): officer imports, a guildmate's Bankers tab updates, the
  sister guild's view updates, and a member who adds `gbank` afterwards does not appear.

## Build order

1. `Guild:BankerEntry` routing every site above through the note rule, with no behaviour change;
   the whole suite green.
2. Data, writer, merge, sync, receive-side officer check.
3. The import.
4. The Officer panel.
5. Player notes (CurseForge, README).
