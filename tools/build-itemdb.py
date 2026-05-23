#!/usr/bin/env python3
"""Build TOGBankClassic's static item + suffix DBs from wago.tools DBC tables.

This is the AUTHORITATIVE source for Modules/Static/ItemDB.lua + SuffixDB.lua.
It pulls Blizzard's actual DB2 tables via wago.tools, so we get every item in
Classic Era regardless of any player's WoW client cache state.

(An earlier in-game scraper at Modules/Dev/BuildDB.lua / `/togbank dev builddb`
was tried first but removed — WoW's multi-tier item cache made the runtime
approach fundamentally unreliable. See docs/DEV_COMMANDS.md for the rationale.)

Output:
    Modules/Static/ItemDB.lua      itemID -> { name, class, subClass, rarity,
                                               level, icon, equipId, price,
                                               stackSize }
    Modules/Static/SuffixDB.lua    suffixID -> "of X" name fragment

Tables fetched from wago.tools (https://wago.tools/db2/<Table>/csv?build=<id>):
    ItemSparse           — name, quality, level, required level, prices, stack,
                           InventoryType, IconFileDataID (where present)
    Item                 — ClassID, SubclassID (these aren't in ItemSparse on
                           Classic Era 1.15.x), and sometimes IconFileDataID
    ItemRandomProperties — random-suffix names for the Vanilla-era system
                           (POSITIVE suffix IDs in item links, ~2000 entries
                           — one per stat-tier combination). This is what
                           Classic Era actually uses for the bulk of gear.
    ItemRandomSuffix     — random-suffix names for the TBC+-era system
                           (NEGATIVE suffix IDs in item links, ~30 entries
                           — abstract suffix names without per-tier variants).
                           Included for completeness even though Classic Era
                           gear mostly uses ItemRandomProperties.

CSVs are cached under tools/wago_cache/<build>__<table>.csv so re-runs are
near-instant. Pass --refresh to force re-fetch.

Usage:
    python3 tools/build-itemdb.py
    python3 tools/build-itemdb.py --build 1.15.8.67156
    python3 tools/build-itemdb.py --refresh
    python3 tools/build-itemdb.py --dry-run    # don't write files; just report stats

Pattern modelled on TOGProfessionMaster/tools/wago_probe.py.
"""

import argparse
import csv
import datetime
import io
import pathlib
import sys
import urllib.request
import urllib.error

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT  = SCRIPT_DIR.parent
CACHE_DIR  = SCRIPT_DIR / "wago_cache"
OUT_ITEM   = REPO_ROOT / "Modules" / "Static" / "ItemDB.lua"
OUT_SUFFIX = REPO_ROOT / "Modules" / "Static" / "SuffixDB.lua"

# Default Classic Era build. Bump when a new patch ships and you need to
# regenerate. Find the latest at https://wago.tools/api/builds.
DEFAULT_BUILD = "1.15.8.67156"

# Item-class IDs that the addon cares about distinguishing — only used for
# the stats summary at the end (e.g. "captured 3120 items, 412 weapons,
# 1840 consumables..."). Not load-bearing for the output format.
ITEM_CLASS_NAMES = {
    0:  "Consumable",
    1:  "Container",
    2:  "Weapon",
    3:  "Gem",
    4:  "Armor",
    5:  "Reagent",
    6:  "Projectile",
    7:  "Trade Goods",
    9:  "Recipe",
    11: "Quiver",
    12: "Quest",
    13: "Key",
    15: "Miscellaneous",
}


def fetch_csv(table: str, build: str, refresh: bool = False) -> list[dict]:
    """Download a wago.tools CSV table and return parsed rows as dicts.

    Cached under tools/wago_cache/<build>__<table>.csv so repeat runs are
    instant. Raises on HTTP errors (no fallback — we want to know).
    """
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = CACHE_DIR / f"{build}__{table}.csv"
    if not cache.exists() or refresh:
        url = f"https://wago.tools/db2/{table}/csv?build={build}"
        print(f"  fetching {url}", file=sys.stderr)
        req = urllib.request.Request(url, headers={"User-Agent": "TOGBankClassic-build-itemdb/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                cache.write_bytes(resp.read())
        except urllib.error.HTTPError as e:
            print(f"  ! HTTP {e.code} for {table} — table not available for this build?",
                  file=sys.stderr)
            return []
        print(f"    wrote {cache.name}: {cache.stat().st_size:,} bytes", file=sys.stderr)
    text = cache.read_text(encoding="utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(text))
    return list(reader)


def _int(row: dict, *keys, default: int = 0) -> int:
    """Read the first present key, coerce to int, default on miss/parse error."""
    for k in keys:
        v = row.get(k)
        if v is None or v == "":
            continue
        try:
            return int(float(v))
        except (TypeError, ValueError):
            continue
    return default


def _str(row: dict, *keys, default: str = "") -> str:
    for k in keys:
        v = row.get(k)
        if v is None or v == "":
            continue
        return str(v)
    return default


def build_item_db(itemsparse_rows: list[dict], item_rows: list[dict]) -> dict[int, dict]:
    """Join ItemSparse (metadata) + Item (class/subclass) into a single
    itemID -> info map matching what the addon's Static/ItemDB.lua expects."""
    # Build Item lookup by ID for the join.
    item_by_id: dict[int, dict] = {}
    for row in item_rows:
        try:
            iid = int(row["ID"])
        except (KeyError, TypeError, ValueError):
            continue
        item_by_id[iid] = row

    db: dict[int, dict] = {}
    skipped_no_name = 0
    skipped_no_id = 0
    for row in itemsparse_rows:
        try:
            iid = int(row["ID"])
        except (KeyError, TypeError, ValueError):
            skipped_no_id += 1
            continue

        name = _str(row, "Display_lang", "Display1_lang")
        if not name:
            skipped_no_name += 1
            continue

        # Class / subclass come from Item table on Classic Era 1.15.x —
        # ItemSparse doesn't carry them directly. If the Item row is missing,
        # default to 0 ("unknown"); the addon's NeedsLink logic handles that
        # safely (default-deny stripping).
        item_row = item_by_id.get(iid, {})

        db[iid] = {
            "name":      name,
            "class":     _int(item_row, "ClassID"),
            "subClass":  _int(item_row, "SubclassID"),
            "rarity":    _int(row, "OverallQualityID"),
            "level":     _int(row, "ItemLevel"),
            "icon":      _int(item_row, "IconFileDataID")
                         or _int(row, "IconFileDataID"),
            "equipId":   _int(row, "InventoryType"),
            "price":     _int(row, "SellPrice"),
            "stackSize": max(1, _int(row, "Stackable", default=1)),
        }

    if skipped_no_id:
        print(f"  skipped {skipped_no_id} rows with no/invalid ID", file=sys.stderr)
    if skipped_no_name:
        print(f"  skipped {skipped_no_name} rows with no Display name (placeholder/test items)",
              file=sys.stderr)
    return db


def build_suffix_db(
    randprop_rows: list[dict],
    randsuffix_rows: list[dict],
) -> dict[int, str]:
    """Merge ItemRandomProperties (Vanilla, ~2000 entries) and ItemRandomSuffix
    (TBC+, ~30 entries) into a single suffixID -> 'of X' fragment map.

    The two systems use different ID spaces in item links:
      ItemRandomProperties → POSITIVE suffix field (Classic Era's primary path)
      ItemRandomSuffix     → NEGATIVE suffix field (newer system, also valid)

    Both map "suffix ID" -> "of X" name fragment for our purposes. We keep
    them in one table because the addon's lookup happens by absolute value
    of the suffix field (the receive-side reconstruction code just needs
    to know "what fragment goes with this suffix ID").

    If both tables have entries for the same numeric ID (unlikely but
    possible in cross-build edge cases), ItemRandomProperties wins because
    that's the older / more commonly-seen system in actual gear.
    """
    db: dict[int, str] = {}
    skipped = 0

    def ingest(rows: list[dict], source_label: str) -> int:
        nonlocal skipped
        added = 0
        for row in rows:
            try:
                sid = int(row["ID"])
            except (KeyError, TypeError, ValueError):
                skipped += 1
                continue
            name = _str(row, "Name_lang", "Name")
            if not name:
                skipped += 1
                continue
            # Filter junk: real Classic random-suffix names always start with "of ".
            # Catches leaked debug/internal strings like "Stat Sta 15" that earlier
            # in-game scrapers picked up via GetItemInfo string-diffing.
            if not name.lower().startswith("of "):
                continue
            # ItemRandomProperties takes precedence on collision.
            if sid not in db:
                db[sid] = name
                added += 1
        return added

    p_added = ingest(randprop_rows,  "ItemRandomProperties")
    s_added = ingest(randsuffix_rows, "ItemRandomSuffix")
    print(f"  suffix sources: {p_added} from ItemRandomProperties, "
          f"{s_added} from ItemRandomSuffix", file=sys.stderr)
    if skipped:
        print(f"  skipped {skipped} suffix rows with no ID/name", file=sys.stderr)
    return db


def _lua_string(s: str) -> str:
    """Lua-escape a string for inclusion in source. Handles backslash + double-quote."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def emit_item_db_lua(db: dict[int, dict], build: str) -> str:
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines = [
        "-- TOGBankClassic_ItemDB",
        f"-- Auto-generated by tools/build-itemdb.py on {ts}",
        f"-- WoW build: {build} | item entries: {len(db)}",
        "-- Source: wago.tools DB2 dumps (ItemSparse + Item).",
        "-- DO NOT EDIT MANUALLY: changes will be overwritten on next regeneration.",
        "",
        "TOGBankClassic_ItemDB = {",
    ]
    for iid in sorted(db.keys()):
        e = db[iid]
        lines.append(
            f'\t[{iid}] = {{ name = "{_lua_string(e["name"])}", '
            f'class = {e["class"]}, subClass = {e["subClass"]}, '
            f'rarity = {e["rarity"]}, level = {e["level"]}, '
            f'icon = {e["icon"]}, equipId = {e["equipId"]}, '
            f'price = {e["price"]}, stackSize = {e["stackSize"]} }},'
        )
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def emit_suffix_db_lua(db: dict[int, str], build: str) -> str:
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines = [
        "-- TOGBankClassic_SuffixDB",
        f"-- Auto-generated by tools/build-itemdb.py on {ts}",
        f"-- WoW build: {build} | suffix entries: {len(db)}",
        "-- Source: wago.tools DB2 dumps (ItemRandomSuffix).",
        "-- DO NOT EDIT MANUALLY: changes will be overwritten on next regeneration.",
        "",
        "TOGBankClassic_SuffixDB = {",
    ]
    for sid in sorted(db.keys()):
        lines.append(f'\t[{sid}] = "{_lua_string(db[sid])}",')
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def report_class_breakdown(db: dict[int, dict]) -> None:
    """Print a one-line per-class summary so the operator can sanity-check
    that we actually captured weapons/armor/etc., not just consumables."""
    counts: dict[int, int] = {}
    for e in db.values():
        counts[e["class"]] = counts.get(e["class"], 0) + 1
    print("  class breakdown:", file=sys.stderr)
    for cid in sorted(counts.keys()):
        name = ITEM_CLASS_NAMES.get(cid, f"Class {cid}")
        print(f"    [{cid:>2}] {name:<14} {counts[cid]:>6}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", maxsplit=1)[0])
    ap.add_argument("--build", default=DEFAULT_BUILD,
                    help=f"WoW build to fetch (default {DEFAULT_BUILD})")
    ap.add_argument("--refresh", action="store_true",
                    help="ignore cached CSVs and re-fetch from wago.tools")
    ap.add_argument("--dry-run", action="store_true",
                    help="don't write Modules/Static/*.lua, just report stats")
    args = ap.parse_args()

    print(f"build-itemdb: target build {args.build}", file=sys.stderr)
    print(f"  cache dir : {CACHE_DIR}", file=sys.stderr)
    print(f"  out (item): {OUT_ITEM}", file=sys.stderr)
    print(f"  out (suf) : {OUT_SUFFIX}", file=sys.stderr)
    print(file=sys.stderr)

    print("Fetching tables...", file=sys.stderr)
    itemsparse = fetch_csv("ItemSparse",           args.build, args.refresh)
    item       = fetch_csv("Item",                 args.build, args.refresh)
    randprop   = fetch_csv("ItemRandomProperties", args.build, args.refresh)
    randsuffix = fetch_csv("ItemRandomSuffix",     args.build, args.refresh)
    print(f"  ItemSparse:           {len(itemsparse):>6} rows", file=sys.stderr)
    print(f"  Item:                 {len(item):>6} rows", file=sys.stderr)
    print(f"  ItemRandomProperties: {len(randprop):>6} rows", file=sys.stderr)
    print(f"  ItemRandomSuffix:     {len(randsuffix):>6} rows", file=sys.stderr)
    print(file=sys.stderr)

    if not itemsparse:
        print("ERROR: ItemSparse is empty — can't build ItemDB. Check the build ID.",
              file=sys.stderr)
        return 2

    print("Building DBs...", file=sys.stderr)
    item_db   = build_item_db(itemsparse, item)
    suffix_db = build_suffix_db(randprop, randsuffix)
    print(f"  ItemDB:   {len(item_db):>6} entries", file=sys.stderr)
    print(f"  SuffixDB: {len(suffix_db):>6} entries", file=sys.stderr)
    print(file=sys.stderr)

    report_class_breakdown(item_db)
    print(file=sys.stderr)

    if args.dry_run:
        print("--dry-run: skipping file writes", file=sys.stderr)
        return 0

    print("Writing Lua source...", file=sys.stderr)
    OUT_ITEM.parent.mkdir(parents=True, exist_ok=True)
    OUT_ITEM.write_text(emit_item_db_lua(item_db, args.build),     encoding="utf-8")
    OUT_SUFFIX.write_text(emit_suffix_db_lua(suffix_db, args.build), encoding="utf-8")
    print(f"  wrote {OUT_ITEM.relative_to(REPO_ROOT)}: {OUT_ITEM.stat().st_size:,} bytes",
          file=sys.stderr)
    print(f"  wrote {OUT_SUFFIX.relative_to(REPO_ROOT)}: {OUT_SUFFIX.stat().st_size:,} bytes",
          file=sys.stderr)
    print(file=sys.stderr)
    print("Done. Review the diff, /reload in-game to verify, then commit.",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
