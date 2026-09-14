# TOGBankClassic Developer Commands

Internal/developer commands available via `/togbank dev <subcommand>`. **None of these are documented to end users** — they are not listed in `/togbank help`, not in `README.txt`, and not in the CurseForge description. This file is the authoritative catalogue.

The dev namespace exists to give developers and maintainers tools for debugging, profiling, and one-off operations without polluting the player-facing command surface or surfacing destructive commands to casual users.

`docs/` is excluded from packaged builds via `.pkgmeta`, so this file ships only to people checking out the repo.

## Quick reference

```text
/togbank dev help                — list dev subcommands (alphabetised)
/togbank dev <subcommand> [args] — invoke a dev subcommand
```

If you type `/togbank dev` with no subcommand (or with `help`), `Chat:ShowDevHelp()` prints the list.

## How a command becomes dev-only

Add the command name to the `DEV_COMMAND_NAMES` table near the top of [Modules/Chat.lua](../Modules/Chat.lua). The dispatcher routes any name in that table through `DEV_COMMAND_HANDLERS` (accessible only via `/togbank dev <name>`) instead of through the top-level `COMMAND_HANDLERS`. The command's entry in `COMMAND_REGISTRY` itself is untouched.

To promote a command back to user-facing, just remove its name from `DEV_COMMAND_NAMES`. The entry is automatically picked up by the top-level dispatcher and `ShowHelp()`.

## Commands

### Database / state inspection

- **`/togbank dev debugdump`** — print a list of keys in `TOGBankClassic_Guild.Info.alts` (truncated at 200). Quick check that the alts table looks right after a sync.
- **`/togbank dev hashdebug`** — print hash-list coverage and which alts are missing from `latestBankerHashes`. Used to diagnose why a banker's data isn't propagating.
- **`/togbank dev hashdump`** — dump the raw `latestBankerHashes` table used for sync comparison, with `OK`/`MISMATCH` per alt against the local data. Heavy output for large guilds — best run on a dummy character or with output captured.
- **`/togbank dev sendqueue`** -- this client's P2P state in one place: send slots in use (and which requesters we have accepted but are still waiting on a state summary from), the send queue with each waiter's position and age, and our own fetch sessions with their state, chosen peer and candidate count. Added with P2P-029 so a queued request can be seen rather than inferred.
- **`/togbank dev trace <banker>`** -- `sendqueue`'s sibling for ONE banker: walks it through every P2P gate in the order the code asks them and prints each answer with its inputs. Serving side (would a sync-request for it be accepted?): on the roster and its number, record held with legacy-row and V2-tuple counts, `CanServe`, `ServableCanon` with the held canon and publish time, the send slot count, and any open state-wait -- stopping with `STOP:` at the first gate that says no. Fetching side: the tab state, the newest advertised canon with the `AdvertisedImproves` verdict and reason, `IsAltSyncPending`, and the live session (state, peer, candidates, tried, the version the request names). Every line calls the production predicate itself, never a copy. Added for the P2P-035 follow-up so "why is this tab red / why does nobody serve it" is one command rather than a debug-log read. Traced on YOUR OWN character it adds the MULTIPC-001 publish gate: whether a peer has named a newer version of you, whether this session's login cycle has answered, when this PC last read the vault / bags / mail (and whether this session), the `CanPublish` verdict with its reason, and whether a scan is waiting to publish -- the thing to run when your own tab is red on a shared-account PC.
- **`/togbank dev persistcheck`** — report request persistence counters: `requests` count, `requestLog` length, `requestLogApplied` actors, `requestLogSeq` actors, and whether `Guild.Info` is the same Lua reference as the SavedVariables faction table. Created during SYNC-001 investigation.
- **`/togbank dev perfstats`** — print `Performance:PrintReport()`. Per-function CPU time tracked by `Performance:Track`. Useful for hot-path profiling.

### Delta sync diagnostics

- **`/togbank dev deltastats`** — bandwidth saved by delta vs full sync, P2P statistics, protocol health (applied vs failed counts, success rate). Heavy output.
- **`/togbank dev deltahistory`** — show stored delta chain for offline recovery (every saved delta per alt with version, size, and timestamp).
- **`/togbank dev deltaerrors`** — recent delta sync errors and per-alt failure counts. First place to look when sync is misbehaving.
- **`/togbank dev clear-delta-errors`** — clear all recorded delta sync errors (`db.deltaErrors.lastErrors`, `failureCounts`, `notifiedAlts`).
- **`/togbank dev clearhistory`** — clear the stored delta chain (`db.deltaHistory`). Forces future syncs to compute new deltas from snapshots rather than replay history.
- ~~`/togbank dev clearsnapshots`~~ — removed in v1.5.0 (INV2-RETIRE-002). It cleared an SV key that has been nil since PERF-012, and the snapshot cache it was meant to reach went with the legacy alt-delta.
- **`/togbank dev resetmetrics`** — zero out `db.deltaMetrics`. Useful before a benchmarking run.
- **`/togbank dev forcedelta on|off`** — flip `FEATURES.FORCE_DELTA_SYNC`. Bypasses size-ratio thresholds, always uses delta. Off by default.
- **`/togbank dev forcefull on|off`** — flip `FEATURES.FORCE_FULL_SYNC`. Disables delta entirely, always sends full snapshot. Off by default.

### Roster

- **`/togbank dev rostercheck`** — verify the `LibGuildRoster-1.0` migration against a live guild
  (ROSTER-003). Three sections, each answering a different question.

  **Library vs the WoW API** — the only genuinely independent check. Scans `GetGuildRosterInfo`
  directly and compares the library's online set against it. Both lists should read *none*.

  > Note the caveat printed in the source: `GetGuildRosterInfo` iteration is filtered by the
  > guild panel's "Show Offline Members" toggle, so with it off the raw member *total* is much
  > smaller than the library's. That is the filter, not a defect — the online *set* is still
  > trustworthy either way.

  **Our cache vs the library** — narrow by construction. `_RefreshFromRosterLib` copies
  `isOnline` straight out of the library, so comparing them back compares the library against a
  copy of itself; it can only catch a bug in the copy loop, never in the library's tracking. Two
  lists, both should read *none*:
  - *In library but not our cache* — a member was dropped during the rebuild.
  - *Normalization disagreement* — **the one that matters.** Two independent implementations
    compared. Every alt record, request and wire message is keyed by normalized name, so a
    mismatch makes lookups miss silently rather than error.

  **Presence transitions since login** — counts of `online` / `offline` / `whisper-not-found`
  seen, plus the last five. This is the part a snapshot *cannot* show: both sides agreeing proves
  the copy is faithful, not that the callbacks are firing at all. On a busy roster, zero
  transitions after a while is itself the signal. `Callbacks were never bound` means
  `Guild:InitRosterCallbacks` did not run, or the library was missing at login.

  Also prints the banker count and, when the local rank cannot read officer notes, a warning that
  bankers tagged only there are invisible — so "0 bankers" is never ambiguous between *none
  tagged* and *cannot see the tags*.

  Run after login once the roster has settled; if it reports "still stabilizing", re-run in a few
  seconds. The `whisper-not-found` counter only moves when a whisper actually bounces, so it
  stays at 0 in normal play.

### Tuple inventory (INV2)

See [INVENTORY_V2.md](INVENTORY_V2.md) for the design these two operate on.

- **`/togbank dev switches [<name> on|off]`** — with no argument, list every switch in
  `TOGBankClassic_Switches.registry` with its live state, description, and whether the value is
  the default or was explicitly set. With arguments, set one.

  The state shown is the **live** answer, not the stored value: a dependent switch reads OFF while
  its parent is off, whatever its own stored value says, because that is what the code actually
  does. Showing the stored value would claim an effect the switch is not having.

  Switches are per-account (`db.global.switches`) and survive a reload, so a half-migrated account
  cannot behave differently per character from one machine.

  **Retired (INV2-RETIRE-003, v1.5.0):** `inventoryV2` and `dualWrite`. The V2 store is the only
  storage format -- the legacy item rows are neither written by the scan nor kept in the
  SavedVariables (they are stripped on load) -- so there is nothing for either switch to choose
  between. A stale value for them in an older `db.global.switches` is ignored, and setting them
  now reports `Unknown switch`. What remains: `sendV2Wire` (the wire diagnostic) and
  `legacyKeyedReceive` (the N6 grace-period switch).

- **`/togbank dev compare` -- retired (INV2-RETIRE-003, v1.5.0).** It diffed the V2 tuple store
  against the legacy item rows on live data, per item ID, and existed for the dual-write period:
  two encodings of one container walk, compared, so a divergence was an encoding bug rather than a
  moved stack. The legacy rows are gone, so there is nothing left to compare the store against. The
  DOC-005 rule it carried still applies to every store-reading command below: the scan fires on
  `BANKFRAME_CLOSED`, not on open, and bags alone trigger nothing.

- **`/togbank dev bandwidth`** -- measure the V2 tuple wire against the legacy link wire, on the
  records this client actually holds. Prints per-character sizes and a total with the reduction
  percentage. Needs a populated V2 store: open the bank and **close** it first (DOC-005).

  **This exists because the obvious method does not work.** `INV2-DOC-001` requires the bandwidth
  figures on the CurseForge page to come from a real guild rather than a synthetic payload, and the
  natural way to get that -- read `togbank-d4` byte counts out of a live `COMMS` log -- cannot
  deliver: `togbank-d4` is only sent when a peer is genuinely behind, so a healthy guild emits no
  sample at all. Two ~200-line live captures during the v1.4.0 rollout contained zero of them.

  **Neither side of the comparison is invented, and that is the whole point.** The V2 figure is the
  real `Wire.encode` output measured by `Wire.estimateSize`. The legacy figure is built from **the
  same rows**, each item's link resolved through `Resolve.describe` -- the real link for the real
  item. It is one inventory measured two ways, not a measurement against an assumption about how
  long an item link is. The reduction is rounded **down**, so a figure published from it is never
  better than what was measured.

### Protocol / network

- **`/togbank dev protocol`** — protocol version distribution across guild members; delta-sync adoption %.
- **`/togbank dev versioncheck`** — broadcast a VersionCheck-1.0 request to the guild, wait 21s, print all responders' versions.
- **`/togbank dev hashupdate`** — (banker only) broadcast hash-list for *all* bank alts to force a guild-wide hash refresh. Heavy. Used after bulk inventory changes.
- **`/togbank dev netq`** — breakdown of the ChatThrottleLib outbound queue by prefix/channel/target. Diagnose congestion or stuck messages.

### Request log

- **`/togbank dev reqscan`** — scan completed requests, report why expired ones aren't being pruned. Created during request-log compaction debugging.

### Data integrity migrations

- **`/togbank dev purgeghosts` -- retired (INV2-RETIRE-003, v1.5.0).** It re-ran the
  linkless-gear-ghost purge (ITEM-004) that fired 30 seconds after login and walked the legacy item
  rows for gear with no link. Those rows are now stripped on load, so the migration and its command
  went together.

### Testing

- **`/togbank dev test` no longer exists**, and neither does `Modules/Tests.lua`. Both were deleted
  in the INV2 step 10 sweep: that harness was written almost entirely against `ComputeDelta` /
  `ApplyDelta` / `ApplyItemDelta`, which went with the legacy link-format wire path under the
  no-backwards-compatibility directive, so most of it was testing functions that no longer exist.
  The offline suite replaces it and is the better tool anyway: it runs without a client, without a
  guild, and without waiting for a sync. From the addon root:

  ```sh
  lua Tests/wowapi/run.lua
  ```

  Do **not** re-add an in-game test command to stand in for it. The one thing an in-game harness can
  do that the offline suite cannot is exercise real client APIs against real data, and that is what
  the diagnostic commands above are for: `dev trace`, `dev hashdebug` and `dev rostercheck` each
  answer a specific question about live state rather than re-running assertions.

### Logging

- **`/togbank dev debuglogsave`** — manually flush the persistent debug log to `TOGBankClassicDB_DebugLog` (normally only happens on logout). User-facing equivalent `/togbank debuglog` (export) and `/togbank debuglogstats` (stats) remain top-level for support workflows.

### Destructive / officer-tier

- **`/togbank dev wipeall`** — (officer only) reset the TOGBankClassic database for self AND every online guild member running the addon. Equivalent of asking the whole guild to type `/togbank wipe`. **Use only when guild-wide corruption needs a hard reset.**

  *Note*: top-level `/togbank wipe` (own-DB-only) remains user-facing and should be the first recommendation when a player reports issues. `wipeall` is dev-only specifically to prevent officers from firing it casually.

## Regenerating the static item / suffix DB

The shipped `Modules/Static/ItemDB.lua` (~24,000 items) and `Modules/Static/SuffixDB.lua` (~2,000 random-suffix fragments) are generated from Blizzard's actual DB2 dumps via [wago.tools](https://wago.tools). The pipeline lives in `tools/build-itemdb.py`. Regenerate when a new patch ships and adds items (Anniversary, SoD content drops, etc.) — the addon's runtime depends on these files being current enough that strip/sync decisions don't fall back to GetItemInfo on cold cache.

**Workflow:**

```sh
# Optional: --refresh to ignore cached CSVs and re-fetch from wago.tools
# Optional: --build 1.15.X.YYYYY to target a specific build (default in script)
# Optional: --dry-run to see counts without overwriting Modules/Static/*.lua

python3 tools/build-itemdb.py
```

The script fetches four DB2 tables (`ItemSparse`, `Item`, `ItemRandomProperties`, `ItemRandomSuffix`), joins on item ID, filters suffix junk (requires fragment to start with "of "), and writes ready-to-commit Lua source. Total runtime ~10–60s depending on cache state. CSV downloads cache under `tools/wago_cache/` (gitignored — regenerable via `--refresh`).

**After regeneration:**

1. Review the diff on `Modules/Static/*.lua` (look at the class breakdown the script prints — should still be ~3000 weapons, ~12000 armor, ~2000 recipes, etc.).
2. `/reload` in-game to verify the addon loads the new file size without freezing.
3. Commit.

There is no in-game scraper — an earlier attempt at one (`Modules/Dev/BuildDB.lua`, `/togbank dev builddb`) was removed because WoW's multi-tier item cache made the runtime approach fundamentally unreliable. The wago.tools path is the authoritative source.

**Pattern reference:** the wago.tools fetch pattern is the same one [TOGProfessionMaster's `tools/wago_probe.py`](https://github.com/EY3G0R3/TOGProfessionMaster) uses. Keep the two tools' approaches aligned — patches that work for one usually work for the other.

## Adding a new dev command

1. Add an entry to `COMMAND_REGISTRY` in [Modules/Chat.lua](../Modules/Chat.lua) exactly as you would a top-level command.
2. Add its `name` to the `DEV_COMMAND_NAMES` table near the top of the same file.
3. Document it in this file under the appropriate section.

That's all — the dispatcher and `ShowDevHelp` pick it up automatically.

## Notes for support

Players who report issues are typically pointed at:

- `/togbank debug` (toggle debug logging)
- `/togbank debuglog [N] [filter]` (export recent log entries)
- `/togbank debuglogstats` (log retention info)
- `/togbank debugtab` / `debugtabremove` (create dedicated chat tab)
- `/togbank wipe` (reset own data)
- `/togbank wipeframes` (reset off-screen windows)

These remain top-level user-facing commands. Don't move them to dev unless you also update the user-facing documentation in `README.txt`.
