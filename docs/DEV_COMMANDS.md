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
- **`/togbank dev persistcheck`** — report request persistence counters: `requests` count, `requestLog` length, `requestLogApplied` actors, `requestLogSeq` actors, and whether `Guild.Info` is the same Lua reference as the SavedVariables faction table. Created during SYNC-001 investigation.
- **`/togbank dev perfstats`** — print `Performance:PrintReport()`. Per-function CPU time tracked by `Performance:Track`. Useful for hot-path profiling.

### Delta sync diagnostics

- **`/togbank dev deltastats`** — bandwidth saved by delta vs full sync, P2P statistics, protocol health (applied vs failed counts, success rate). Heavy output.
- **`/togbank dev deltahistory`** — show stored delta chain for offline recovery (every saved delta per alt with version, size, and timestamp).
- **`/togbank dev deltaerrors`** — recent delta sync errors and per-alt failure counts. First place to look when sync is misbehaving.
- **`/togbank dev clear-delta-errors`** — clear all recorded delta sync errors (`db.deltaErrors.lastErrors`, `failureCounts`, `notifiedAlts`).
- **`/togbank dev clearhistory`** — clear the stored delta chain (`db.deltaHistory`). Forces future syncs to compute new deltas from snapshots rather than replay history.
- **`/togbank dev clearsnapshots`** — clear delta computation snapshots (`db.deltaSnapshots`). Forces the next outbound sync to be a full snapshot rather than a delta.
- **`/togbank dev resetmetrics`** — zero out `db.deltaMetrics`. Useful before a benchmarking run.
- **`/togbank dev forcedelta on|off`** — flip `FEATURES.FORCE_DELTA_SYNC`. Bypasses size-ratio thresholds, always uses delta. Off by default.
- **`/togbank dev forcefull on|off`** — flip `FEATURES.FORCE_FULL_SYNC`. Disables delta entirely, always sends full snapshot. Off by default.

### Protocol / network

- **`/togbank dev protocol`** — protocol version distribution across guild members; delta-sync adoption %.
- **`/togbank dev versioncheck`** — broadcast a VersionCheck-1.0 request to the guild, wait 21s, print all responders' versions.
- **`/togbank dev hashupdate`** — (banker only) broadcast hash-list for *all* bank alts to force a guild-wide hash refresh. Heavy. Used after bulk inventory changes.
- **`/togbank dev netq`** — breakdown of the ChatThrottleLib outbound queue by prefix/channel/target. Diagnose congestion or stuck messages.

### Request log

- **`/togbank dev reqscan`** — scan completed requests, report why expired ones aren't being pruned. Created during request-log compaction debugging.

### Data integrity migrations

- **`/togbank dev purgeghosts`** — manually re-run the linkless-gear-ghost purge that normally fires 30 seconds after login. Useful when the shipped static `TOGBankClassic_ItemDB` has been regenerated (via `tools/build-itemdb.py`) and you want to re-classify items the previous run skipped. Prints a result line every time (purged count + skipped-suspect count).

### Testing

- **`/togbank dev test [test-name|all|help]`** — run the test suite in [Modules/Tests.lua](../Modules/Tests.lua). `/togbank dev test help` lists individual test names.

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
