# TOGBankClassic offline test suite

Runs the addon's Lua against a fake WoW client, with no game and no LuaRocks. Needs only a
Lua 5.1 interpreter.

## Running

From the addon root (the directory holding `TOGBankClassic.toc`):

```sh
lua Tests/wowapi/run.lua                      # whole suite
lua Tests/wowapi/run.lua Tests/item_spec.lua  # one file
```

**Always run the whole suite before reporting results.** The entire run shares one Lua state
and specs reassign globals freely, so a spec that corrupts state passes in isolation and breaks
a *later file*. That failure mode is invisible in a single-file run.

Coverage for one module:

```sh
lua Tests/coverage.lua Modules/Item.lua Tests/item_spec.lua
```

`busted` also works (`.busted` defers to the shared config in the submodule), but it is not
needed and not installed here — the bundled runner exists because busted pulls in `luasystem`,
whose MSVC build chain fights Windows badly, doubly so under `C:\Program Files (x86)`.

## First-time setup

The harness is a git submodule. After a fresh clone:

```sh
git submodule update --init --recursive
```

## Layout

| Path | What it is |
| --- | --- |
| `Tests/wowapi/` | The shared WoWAPITesting harness (submodule — **do not edit**) |
| `Tests/env_togbank.lua` | The fake WoW environment this addon needs on top of the harness |
| `Tests/coverage.lua` | Zero-dependency line coverage, from Lua 5.1 bytecode debug info |
| `Tests/*_spec.lua` | The specs |
| `Tests/HARNESS_CONTRACT.md` | Proposed harness additions, staged locally — hand upstream |

`Tests` is in `.pkgmeta`'s `ignore` list, so none of this reaches players.

## Writing specs

Start with the environment and reset it per test:

```lua
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

describe("Thing", function()
    before_each(function()
        env.reset()          -- total reset: clears state AND reinstalls every global
        env.stubOutput()     -- silent logger, or env.loadOutput({BANK = true}) for a real one
        env.loadFile("Modules/Thing.lua")
    end)
end)
```

House rules, in rough order of how much pain each one has saved:

- **Write the spec for how the code *should* behave, then fix the code.** A test that ratifies
  current behaviour locks the bug in. When a spec fails, the default assumption is that the
  code is wrong. Re-baselining an assertion to match the implementation needs a stated reason.
- **`env.reset()` in `before_each`, always.** It reinstalls every global, not just the state
  tables — partial resets let one spec corrupt later spec *files*.
- **Never put an assertion behind a condition that might not hold.** A silently-skipped
  assertion reads as a pass. If a spec needs a precondition, assert the precondition too.
- **Stub collaborators as methods.** Addon modules call each other with `:`, so a stub needs
  the `self` slot: `function(_, payload)`, not `function(payload)`. Getting this wrong produces
  confusing nil-field failures that look like addon bugs.
- **Time only moves when you move it.** Nothing scheduled runs until `env.advance(seconds)` or
  `env.flushTimers()`.
- **Cite the audit ID in the failure message** when a spec pins a known finding
  (`(audit ITEM-005)`), so a failing run explains itself without a trip to the docs.

## Current state

Failing specs are expected right now: they are
[docs/AUDIT_2026-08-03.md](../docs/AUDIT_2026-08-03.md) made executable. Every failure names
the audit ID it pins. They turn green as the findings are fixed — none of them should be
"fixed" by weakening the assertion.
