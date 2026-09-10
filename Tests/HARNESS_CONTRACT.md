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

---

## 8. Adoption -- 2026-09-08 -- the answer to sections 1-6 arrived a month ago and this addon never saw it

**Everything above was answered on 2026-08-07.** The response is in the harness repo at
`docs/contracts/TOGBankClassic.md`, which was **frozen on 2026-08-14** when the protocol changed to
put both sides of the conversation in this file. TOGBank's pin was `c46cb89` (2026-08-02), so the
answer sat one commit range away, unreadable from here, for a month. Pin moved to `d54c49a` today.

**This is exactly the failure the protocol change was made to stop**, quoted from the frozen file:
*"this file could only ever be read by the harness, so a delivered contract was indistinguishable
from an ignored one from the addon's side, permanently, at any pin."* Recorded here rather than only
in a changelog, so the next reader of *this* file learns it is answered.

| # | Item | Harness verdict, 2026-08-07 |
| --- | --- | --- |
| 1 | Controllable clock + timer queue | **Delivered** in `env/wow.lua` (not `env/timer.lua`) |
| 2 | Container / bag API | **Completed 2026-08-07**, including the nilable asymmetry |
| 3 | Guild roster API | **Delivered** as `env/guild.lua` |
| 4 | Item / ItemMixin API | **Delivered**, both contract points |
| 4a | `securecallfunction` + CallbackHandler loader | **Delivered** |
| 4b | Localized system-message globals | **Delivered**, hyperlink form intact |
| 5 | `assert.has_no_error` | **Delivered** |
| 6 | `coverage.lua` | **Delivered.** Local fork deleted 2026-09-08 |

**The headline contract held and the harness verified it rather than assuming:** `C_Timer.After` is
`env/wow.lua:795` and returns nothing. DeltaSync raised the identical contract independently.

### Done in this adoption

- **Pin moved** `c46cb89` -> `d54c49a`. **The suite stayed green with no changes at all: 488
  passed, 0 failed.** That is worth distrusting rather than celebrating -- see the open item below.
- **`Tests/coverage.lua` deleted**, as the response instructs. It was 209 lines against the
  harness's maintained 489. `Tests/README.md` and `docs/INVENTORY_V2.md` now point at
  `Tests/wowapi/coverage.lua`. The two `Tests/coverage.lua` mentions in `docs/LIBRARY_CONTRACTS.md`
  are **deliberately untouched**: they are DeltaSync's and AceCommQueue's own quoted text about
  their own repo roots, inside an append-only block.

### Still open, and the first one is the real work

- **`Tests/env_togbank.lua` still stages items 1, 3, 4, 4a and 4b locally**, which the response says
  to drop. It has not been dropped, and this is why the suite went green with zero changes: the
  addon overrides most of the harness env with its own state-driven versions, so a month of `env/`
  fixes could neither break it nor help it. **A green suite here is evidence that the harness is
  barely being used, not that adoption was clean.**

  This is not a mechanical deletion. The file's own design note says the overriding is deliberate --
  the specs steer state through `env.setBag`, `env.addGuildMember`, `env.defineItem`, `env.advance`
  -- and the harness's shapes differ (`wow.advanceTime`, `wow.timers`, `env/guild.lua`'s own roster).
  Migrating means rewriting spec-facing helpers across 488 examples. It should be done deliberately,
  in a session whose subject is that, not folded into a pin move.

- **Keep and re-raise, per the response:** `flushTimers()`, `pendingTimerCount()`, `GetServerTime`
  and `debugprofilestop` are absent from the harness by name. `#wow.timers` is the same observation
  as `pendingTimerCount()`, but the other three are genuinely not there, and `advance()`'s
  callback-budget abort is not implemented upstream either. TOGBank's local versions stay until
  these land.

## 9. NUM_BANKGENERIC_SLOTS -- 2026-09-08 -- the harness asked US for this value and nobody answered

**What:** the numeric value of `NUM_BANKGENERIC_SLOTS` (`BANK_NUM_GENERIC_SLOTS`), so the harness can
ship it instead of a spec asserting its absence.

**Why:** the harness declined to guess it, and said so explicitly rather than quietly inventing one:
the constant appears exactly once in the Classic Era source tree and is never assigned a numeric value
there, and *"a wrong constant behind an assertion is worse than an absent one."* It asked the one
consumer that has both a bank addon and a live client -- this one -- to print it and re-raise. That
was 2026-08-07 and it has not been done, purely because nobody here could read the request.

**Contract:** print `NUM_BANKGENERIC_SLOTS` from a live Classic Era client and, separately, from a
TBC client, since this addon ships both flavours and the value need not agree. Re-raise here with the
values and where they were read. **This one is blocked on the operator, not on the harness.**

## 10. `C_ChatInfo.RegisterAddonMessagePrefix` returns an ENUM, not a bool -- the stub returns `true` and its own comment says it was never verified

**What:** `env/wow.lua`'s `C_ChatInfo.RegisterAddonMessagePrefix` should return
`Enum.RegisterAddonMessagePrefixResult.Success` (numeric `0`), not `true`, and the
`RegisterAddonMessagePrefixResult` enum should exist so a spec can name its values.

**Why -- this is the "a permissive stub PICKS the answer" class, from your own `CLAUDE.md`.** The
stub at `env/wow.lua:1079-1082` returns `true`, and the comment directly above it says the return
value *"is not specified by any contract we hold and is NOT verified against Blizzard's docs"*. It is
specified, and it is in the tree the harness's own rules point at.
`wow-ui-source-classic_era/Interface/AddOns/Blizzard_APIDocumentationGenerated/ChatInfoDocumentation.lua:332-335`:

```lua
Returns =
{
    { Name = "result", Type = "RegisterAddonMessagePrefixResult", Nilable = false },
},
```

and `ChatConstantsDocumentation.lua:130-141` gives the four values: `Success = 0`,
`DuplicatePrefix = 1`, `InvalidPrefix = 2`, `MaxPrefixes = 3`.

**The concrete cost, which is why this is worth a contract rather than a local override.** TOGBank
has an open work item (`LIBREQ-ALL-005`) to check this return and log a loud failure, and the
obvious implementations are all silently dead in game against the real client:

- `if not C_ChatInfo.RegisterAddonMessagePrefix(p) then` -- **never fires.** Success is `0`, and `0`
  is truthy in Lua.
- `if result == false then` -- **never matches.** The function never returns a boolean.

Both pass their specs against a stub returning `true`, because `true` is also not `false`. So the
guard would be written, tested, shipped and never once execute -- and the failure it exists to catch
(`MaxPrefixes`, a client-wide cap that a player with many addons can genuinely hit) stays invisible.
That is the TOGProfessionMaster `GetSpellInfo` shape exactly: a branch that had never run offline.

**Contract:**

> `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` returns a **number** from
> `RegisterAddonMessagePrefixResult`, never a boolean and never nil. Default `Success` (`0`).
> `Enum.RegisterAddonMessagePrefixResult` must carry all four named values so specs assert
> `Enum.RegisterAddonMessagePrefixResult.MaxPrefixes` rather than a bare `3`. A spec must be able to
> steer the result to drive a consumer's failure branch.

**Note for whoever applies it: this will turn consumers RED, and that is the fix working** -- anything
currently asserting a truthy return is asserting the stub. Flag it in the Adoption log.

**Also worth deciding on the harness side:** `DuplicatePrefix` is **not** a failure for a consumer.
AceComm registers the prefix first, so an addon that checks its own prefixes registers second and
gets `DuplicatePrefix` every time. A consumer's guard must treat `Success` and `DuplicatePrefix` as
fine and only `InvalidPrefix` / `MaxPrefixes` as loud -- worth stating in the Adoption entry, because
the naive reading of "duplicate" is "something went wrong".

**Blocked on this:** `LIBREQ-ALL-005`'s host half. A spec written against today's stub would ratify a
guard that cannot fire, which is worse than not having the guard.
