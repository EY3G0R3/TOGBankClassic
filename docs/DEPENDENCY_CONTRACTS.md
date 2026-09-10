# Dependency contracts

Contract traffic for **TOGBankClassic** — what consumers need from it, and what
it needs from code it does not own.

Same file, same name, same place as every other addon in this tree. Format
follows `TOGProfessionMaster/docs/DEPENDENCY_CONTRACTS.md`.

## Why this file exists

**Other repos are read-only from here.** When work in TOGBankClassic needs
something from a dependency, the fix is not made in that dependency's source — it
is written up here and applied upstream separately, by hand, in that repo.
Reading a dependency's source to find the right integration point is fine and
expected; editing it is not.

Each entry states **what** is needed, **why** (traced to the behaviour that
forced it), and the **exact contract** — the API shape, so the change is
unambiguous. Where a consumer ships a workaround in the meantime, the entry says
so and what it costs, because that is what gets deleted once the contract lands.

**Append, never rewrite.** A response goes directly under its request as a
`> **TOGBankClassic response — YYYY-MM-DD — DELIVERED | DECLINED | PARTIAL**`
block. Disagreeing is useful and should be recorded; silently changing the
question so the answer looks better is not. A declined request stays, with its
reasoning, so nobody re-raises it in six months.

**This is not the harness contract file.** Requests against the shared
WoWAPITesting harness go in `Tests/HARNESS_CONTRACT.md`. This file is for sibling
addons and libraries.

## Who TOGBankClassic talks to

| Repo | Direction | What flows |
| --- | --- | --- |
| **TOGProfessionMaster** | TOGPM → TOGBankClassic | reads `TOGBankClassic_Guild` for banker stock; calls `TOGBankClassic_TooltipBankerInfo:AppendTo`, see §1 |
| **Baganator** | optional, one-way | `API.RequestItemButtonsRefresh` for bag highlighting |

---

## 1. A callable renderer for the bankers block

**Raised by:** TOGProfessionMaster, 2026-08-06.
**Status:** delivered 2026-08-08.

### What is needed

A public function that draws the "Bankers:" block into a tooltip the caller
owns:

```lua
-- Returns true if it added lines, false if no banker holds the item.
-- Must never raise: the caller may be mid-tooltip with no item context.
TOGBankClassic_TooltipBankerInfo:AppendTo(tooltip, itemId)
```

TOGBankClassic's own `OnTooltipSetItem` handler should then call it too, so there
is exactly **one** implementation of the layout.

### Why

`Modules/TooltipBankerInfo.lua:15` defines `OnTooltipSetItem` as a **file-local
closure**, installed at line 58 via
`GameTooltip:HookScript("OnTooltipSetItem", …)`. It is reachable only through
that hook, and the hook only fires for a tooltip that carries a real **item**.

TOGProfessionMaster draws recipe tooltips for the roughly one third of recipes
that are trainer-taught and have **no teaching item at all** — those are built
from `AddLine` calls, so `OnTooltipSetItem` never fires and the bankers block is
silently absent on exactly the tooltips where a player is most likely to be
asking "can I get these reagents from the bank?".

### The workaround shipping today, and what it costs

TOGPM re-renders the block itself in `GUI/SharedWidgets.lua`
(`ItemLink.AppendIntegrations`), reading `addon.Bank.GetBanksWithItem` — which
reads the same `TOGBankClassic_Guild` data. It works, and it is **duplicated
layout**: TOGPM has copied the heading text, the colours (`1, 0.82, 0` for the
title, `0.4, 0.8, 1` for "Bankers:") and the `AddDoubleLine` name/count shape.

The day TOGBankClassic restyles that block, the two stop matching and nothing
fails — it just quietly looks wrong in one addon. That is the whole cost, and it
is why the fix belongs here rather than there.

### Precedent

This is the shape ItemDB settled on for third-party addons it cannot change:
`LibItemDB-1.0:AttachExternalRecipeInfo(tooltip, spellID)` wraps AllTheThings'
`AttachTooltipSearchResults`, returns whether lines were added, and never raises.
TOGBankClassic differs in one respect that makes this **easier**, not harder — it
is ours, so the renderer can simply be exposed rather than bridged.

### Note on keying

`AppendTo` keyed by **item id** is correct here: bank stock is a fact about an
item. (ItemDB's ATT bridge is keyed by *spell* precisely because a recipe may
have no item — that constraint does not apply to bank contents.)

> **TOGBankClassic response — 2026-08-08 — DELIVERED.**
> `TOGBankClassic_TooltipBankerInfo:AppendTo(tooltip, itemId)` exists with the
> signature as asked, in `Modules/TooltipBankerInfo.lua:31`. It returns `true`
> when it added lines and `false` otherwise, and it never raises: it type-checks
> both arguments and returns `false` for a nil or shapeless tooltip, a non-number id, or
> absent bank data. `OnTooltipSetItem` is now a four-line adapter that pulls the
> id out of the link and calls it, so there is exactly one implementation of the
> layout, as requested. Specs: `Tests/tooltipbankerinfo_spec.lua` (14), including
> one that drives the hook and asserts it renders *through* `AppendTo` — so a
> future copy grown inside the hook fails rather than silently drifting again.
>
> **Two things changed that the request did not ask for, both worth knowing.**
>
> 1. **The lines now pass the tooltip `wrap` flag.** `AddLine`'s fifth argument
>    defaults to `false`, and an unwrapped line ignores the client's engine-side
>    preset width and stretches the shared `GameTooltip` — dragging every other
>    addon's content out with it. This block had never passed it. The two
>    `AddDoubleLine` calls take no such flag and need none: a character name and
>    a stack count are both short by construction. See the harness's
>    `docs/TOOLTIPS.md`.
> 2. **The workaround was not the faithful mirror the request believed it was.**
>    The request says TOGPM "deliberately mirrors its heading + `AddDoubleLine`
>    shape", and the *layout* did match. The *data* did not, in four ways:
>    TOGPM walked `TOG:GetBanks()` (designated bankers) where this walks every
>    alt passing `IsInCurrentGuildRoster`; TOGPM showed the raw `"Name-Realm"`
>    where this strips the realm; TOGPM sorted by name only where this sorts by
>    stock descending then name; and — the real defect — **TOGPM took the first
>    matching entry and `break`ed where this sums them.** A bank stores one entry
>    per stack, so 60 Copper Bars in a 20-stack bank is three entries: TOGPM
>    reported 20. That was visible twice, in the tooltip count and in
>    `ShowRequestDialog`, which sums those counts into `totalStock` and caps
>    `maxRequestable` from it, so a player could not request past the first
>    stack. Fixed on their side in `Compat.lua:GetBanksWithItem` with three specs.
>    Recorded here because it is the argument for this contract, not against it:
>    the layouts were kept in step by hand and the data quietly was not.

---

## 2. `TOGBankClassic.RequestItem` does not exist — resolved on the caller's side

**Raised by:** TOGProfessionMaster, 2026-08-06.
**Status:** closed, no action needed here.

Recorded so it is not re-derived. TOGPM's Shopping List called
`TOGBankClassic.RequestItem(itemId)` behind a
`if TOGBankClassic and TOGBankClassic.RequestItem then` guard. `_G.TOGBankClassic`
is this addon's UI controller **frame** (`Modules/UI.lua:244`) and has never
carried such a field — the only `RequestItem*` symbol anywhere in this repo is
Baganator's `RequestItemButtonsRefresh` in `Modules/ItemHighlight.lua`.

So the guard was never true and those buttons did nothing, silently, because the
guard swallowed the miss. **No API is requested**: TOGPM fixed it on its side by
routing through its own `addon.Bank.ShowRequestDialog`, which every other surface
in that addon already used.

The transferable point, and the reason this is written down: a
`if X and X.f then X.f() end` guard around a call to another addon cannot
distinguish "not loaded" from "loaded, and I got the name wrong". Both look like
a no-op forever.
