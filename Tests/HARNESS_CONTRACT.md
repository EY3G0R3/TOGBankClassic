# Harness contract — proposed additions to WoWAPITesting

`Tests/wowapi` is a git submodule of <https://github.com/Pimptasty/WoWAPITesting>, shared by
roughly twenty addons. **Nothing in this document has been applied to that repo.** Each item
below is staged locally so this addon's suite runs today, with the intended upstream home
named. Hand these to the harness maintainer rather than editing the submodule in place.

Staging locations:

- `Tests/env_togbank.lua` — everything in sections 1-4
- `Tests/coverage.lua` — section 6 (copied verbatim from `GuildRoster/Tests/coverage.lua`,
  which already proposes the same move)

---

## 1. A controllable clock and timer queue → `env/timer.lua`

**What:** `GetTime`, `GetServerTime`, `time`, `date`, `debugprofilestop` driven by a single
advanceable `now`, plus a full `C_Timer` (`After`, `NewTimer`, `NewTicker`) whose callbacks are
queued rather than run, with `advance(seconds)`, `flushTimers()` and `pendingTimerCount()`.

**Why:** Every TOG addon schedules work. Without a fake clock, anything time-dependent is
either untestable or tested by sleeping. `pendingTimerCount()` in particular is what lets a
spec assert that a cancel actually cancelled something.

**Contract — the part that matters most:**

> `C_Timer.After(delay, fn)` **must return nothing.** Only `NewTimer` and `NewTicker` return a
> handle carrying `:Cancel()`.

This mirrors the real API exactly. It is called out because the convenient stub — returning a
handle from `After` too — silently destroys the harness's ability to catch a whole bug class.
TOGBankClassic currently stores `C_Timer.After`'s result in eight places and calls `:Cancel()`
on it; each cancel sits behind an `if timer then` guard, so it is a silent no-op that looks
identical to a working cancel. A permissive stub makes all eight specs pass. Audit `TIMER-001`.

`advance()` must re-scan the queue after each callback, because callbacks routinely schedule
more timers, and must abort with a clear error if a run exceeds a sane callback budget — a
timer storm should report itself, not hang the suite.

## 2. Container / bag API → `env/container.lua`

**What:** `C_Container.GetContainerNumSlots`, `.GetContainerNumFreeSlots`,
`.GetContainerItemInfo`, plus `BANK_CONTAINER`, `NUM_BANKGENERIC_SLOTS`,
`ATTACHMENTS_MAX_RECEIVE`, backed by a `bags` table a spec can populate.

**Why:** Any addon that reads a player's inventory needs this, and hand-rolling it per addon
guarantees the return shapes drift. `GetContainerItemInfo` returns a **table** (not the old
positional list) on every currently-supported client, and that shape is easy to get wrong from
memory.

**Contract:** `GetContainerNumFreeSlots` returns `(freeSlots, bagType)`, and `bagType` being
non-nil is what the addon uses to detect "the bank is actually open" — so a bag that does not
exist must return a nil second value, not `0`.

## 3. Guild roster API → `env/guild.lua`

**What:** `GetNumGuildMembers`, `GetGuildRosterInfo`, `C_GuildInfo.GuildRoster`,
`C_GuildInfo.CanViewOfficerNote`, `IsInGuild`, `GetGuildInfo`, backed by a roster array.

**Why:** GuildRoster already stages an `env_guild.lua` for the same reason; this is the second
consumer, which is the point at which it should move upstream. Note the two staged copies were
written independently and should be reconciled into one.

**Contract:** `GetGuildRosterInfo` is positional and the order is load-bearing —
`name, rank, rankIndex, level, classLocalized, zone, note, officerNote, online, status, class`.
The addon reads slots 7 and 8 (the notes) to identify bankers, so slots must not be collapsed.

## 4. Item / ItemMixin API → `env/item.lua`

**What:** `GetItemInfo`, `GetItemInfoInstant`, `GetItemQualityColor`, `C_Item.*`, and an
`Item.CreateFromItemID` returning an object with `.itemID` and `:ContinueOnItemLoad(cb)`.

**Why:** Item loading is asynchronous in-game, and the async path is where the interesting bugs
live (see audit `ITEM-005`). A stub that resolves synchronously cannot exercise them.

**Contract:**

- `GetItemInfo` returns **nil** for an uncached item. Cold-cache behaviour is a real state the
  addon must handle, not an edge case; a stub that always returns data hides it entirely.
- `ContinueOnItemLoad` must defer through the timer queue, so a spec has to `advance()` for the
  callback to land. Resolving inline would make async ordering bugs invisible.

## 4a. CallbackHandler prerequisites → `env/CallbackHandler.lua`

**What:** `securecallfunction` (and `securecall`), plus the loader that registers the real
`CallbackHandler-1.0` from the sibling Ace3 install.

**Why:** any library built on CallbackHandler — LibGuildRoster, DeltaSync, AceEvent — is unusable
offline without these. GuildRoster already stages the loader half in its own `env_guild.lua`, and
TOGBankClassic now stages the same thing; that is two consumers, which is the point at which it
should move.

**Contract:** `securecallfunction` is captured by CallbackHandler as a **file-scope upvalue**, so
it must exist *before* CallbackHandler is loaded. Setting it afterwards is a silent no-op and
every callback dispatch then fails with `attempt to call upvalue 'securecallfunction'`. Offline it
is a plain forwarding call: `function(fn, ...) return fn(...) end`.

## 4b. Localized system-message globals → `env/wow.lua`

**What:** `ERR_FRIEND_ONLINE_SS`, `ERR_FRIEND_OFFLINE_S`, `ERR_GUILD_JOIN_S`, `ERR_GUILD_LEAVE_S`,
`ERR_GUILD_REMOVE_SS`.

**Why:** LibGuildRoster derives its online/offline/join/leave chat patterns **from these strings**
rather than hardcoding English — the right design, and it makes the globals a hard prerequisite.

**Contract — the part that cost real debugging time:** the patterns are built at **file scope**
(`LibGuildRoster-1.0.lua:293-306`), so the globals must exist *before the library loads*. Set them
afterwards and the library silently matches **nothing** — no error, no warning, presence tracking
simply never fires. That failure looks exactly like a library bug and is not one.

The online form must carry the player hyperlink the real message has:

```lua
ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online."
```

A plain `"%s has come online."` would let a hyperlink-stripping regression pass unnoticed.

## 5. `assert.has_no_error` → `run.lua`

**What:** the complement of the existing `assert.has_error`.

**Why:** "this input must not raise" is a common assertion — nil guards, malformed saved data,
empty strings. Today it has to be spelled out as `pcall` plus `assert.is_true`, which loses the
error message unless the spec threads it through by hand. Real busted (luassert) provides it,
so specs written against the bundled runner are currently a strict subset of what runs on CI.

Suggested shape, matching the existing style:

```lua
function A.has_no_error(fn, msg)
    local ok, err = pcall(fn)
    if not ok then fail((msg or "expected no error") .. "\n    raised: " .. tostring(err)) end
end
```

## 6. `coverage.lua` → harness root, alongside `run.lua`

**What:** the zero-dependency line-coverage tool.

**Why:** already proposed by `GuildRoster/Tests/HARNESS_CONTRACT.md`; this repo is the second
consumer and now carries a byte-identical copy. Two copies of a 200-line bytecode reader is
exactly the duplication the submodule exists to prevent. Nothing in it is addon-specific.

**Note for whoever applies it:** it takes the executable-line set from Lua 5.1 bytecode debug
info rather than guessing from source text, so it must keep working under whatever Lua the
harness targets. If the harness ever moves off 5.1 this needs revisiting rather than porting
blind.

---

## 7. Not proposed for upstream

These stay in `Tests/env_togbank.lua` because they are genuinely TOGBank-specific:

- `MODULE_ORDER` and `loadModules` — mirrors this addon's `.toc` ordering.
- `loadOutput` / `stubOutput` — wires this addon's logging module.
- `defineItem` / `setBag` / `addGuildMember` — thin fixture sugar over the generic env.

One quirk worth flagging if a generic loader is ever added upstream: `loadFile` strips a UTF-8
BOM and retries. `Modules/Options.lua` currently carries one (audit `LINT-001`), and without
the retry it reports as an unexplained "could not load" rather than as the real finding.
