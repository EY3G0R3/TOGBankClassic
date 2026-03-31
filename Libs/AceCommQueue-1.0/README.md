# AceCommQueue-1.0

A transparent send-queue library for World of Warcraft addons that use AceComm-3.0.

## The Problem

AceComm-3.0 splits large messages into `FIRST`/`NEXT`/`LAST` chunks and hands them all to ChatThrottleLib (CTL) at once. CTL maintains separate priority rings — `ALERT`, `NORMAL`, `BULK` — and drains `ALERT` before `NORMAL` before `BULK`.

If a second message is submitted on the same prefix immediately after a large first message, and the two use different CTL priorities, CTL can drain the second message's chunks **ahead of remaining chunks from the first message**. The receiver's AceComm spool is keyed on `prefix + sender`. When a new `FIRST` frame arrives mid-stream, the partial spool is overwritten — the assembled payload is garbage and the CRC check fails.

```
BULK  message: FIRST ─── NEXT ─── NEXT ─── LAST
NORMAL message:            FIRST ─ LAST
                                ↑
                      receiver spool corrupted here
```

## The Solution

AceCommQueue-1.0 maintains an **app-level queue** per `(prefix, distribution, target)`. Only one message is ever active in CTL at a time for that combination. The next queued message is not submitted until CTL's callback confirms the previous message's final chunk was handed off.

Between messages, higher-priority items drain first (`ALERT > NORMAL > BULK`), so an urgent message pushed onto the queue still goes out before pending lower-priority traffic.

## Requirements

- LibStub
- AceComm-3.0

## How It Works

`Embed` wraps the addon object's existing `SendCommMessage` with a queued dispatcher. The original `SendCommMessage` — whether AceComm's directly or a chain of wrappers you've already installed — is captured at embed time and called internally by the drain when a slot is available.

All existing call sites in your addon use `self:SendCommMessage(...)` unchanged. Queueing is fully transparent.

## Integration

### Step 1 — Load the library

**As embedded (ship the file in your own Libs folder):**

Add to your `.toc` before your own files:
```
Libs\LibStub\LibStub.lua
Libs\AceCommQueue-1.0\AceCommQueue-1.0.lua
```

**As external (standalone addon, user installs separately):**

Declare the dependency in your `.toc`:
```
## Dependencies: AceCommQueue-1.0
```

### Step 2 — Embed into your addon

In your addon's `OnInitialize` (or equivalent), embed AceCommQueue-1.0 **after** AceComm-3.0 and any `SendCommMessage` wrappers:

```lua
function MyAddon:OnInitialize()
    -- AceComm must already be embedded first
    AceComm:Embed(self)

    -- Optional: install any wrappers around SendCommMessage here

    -- AceCommQueue must be last so it wraps the complete chain
    local ACQ = LibStub("AceCommQueue-1.0")
    ACQ:Embed(self)
end
```

After this, every call to `self:SendCommMessage(...)` in your addon goes through the queue automatically.

### Step 3 — Register the slash command (optional)

If you want to be able to toggle debug output and inspect queue state at runtime, call `RegisterSlashCommand` in `OnInitialize`:

```lua
LibStub("AceCommQueue-1.0"):RegisterSlashCommand("/acq")
```

See the [Slash Commands](#slash-commands) section for what each command does.

## Suppression Compatibility

If your addon has a wrapper around `SendCommMessage` that sometimes suppresses sends (for example, a guard that blocks sends while in a raid), the wrapper **must** call the callback with `(callbackArg, 0, 0, nil)` when suppressing. This satisfies the library's last-chunk detection (`sent >= total`, where `0 >= 0`) and unblocks the queue so it never stalls permanently.

```lua
-- Example suppression wrapper
local originalSend = target.SendCommMessage
target.SendCommMessage = function(self, prefix, text, dist, target, prio, callbackFn, callbackArg)
    if isInRaid() then
        -- Must unblock the queue
        if callbackFn then callbackFn(callbackArg, 0, 0, nil) end
        return
    end
    originalSend(self, prefix, text, dist, target, prio, callbackFn, callbackArg)
end
```

Install this wrapper **before** calling `ACQ:Embed(self)` so AceCommQueue wraps the complete chain.

## API Reference

### `AceCommQueue:Embed(target)`

Wraps `target.SendCommMessage` with the queued dispatcher.

- `target` — the addon table. Must already have `SendCommMessage` (i.e. AceComm-3.0 must be embedded first).
- Safe to call multiple times; subsequent calls on the same object are silently ignored.
- Returns `target` for chaining.

### `AceCommQueue:SetDebug(flag)`

Enable or disable debug output at runtime.

- `flag` — `true` to enable, `false` to disable.
- Debug is **off by default**.

### `AceCommQueue:RegisterSlashCommand(cmd)`

Register a slash command to control the library at runtime. Call once — either from the host addon's `OnInitialize`, or from a standalone wrapper's `ADDON_LOADED` handler.

- `cmd` — a slash command string including the slash, e.g. `"/acq"`.

## Slash Commands

All commands below assume `RegisterSlashCommand("/acq")` was called. Substitute your chosen command.

| Command | Description |
| --- | --- |
| `/acq` | Toggle debug output on/off |
| `/acq on` | Enable debug output |
| `/acq off` | Disable debug output |
| `/acq status` | Print the current state of all queues — key, in-flight flag, and item count per priority bucket |

Debug output appears in the chat frame and includes: enqueue events (prefix, dist, priority, queue depth), drain events (which item is being sent), completion events (bytes sent vs total, suppression detection), send errors, and idle state when all buckets are empty.

## Standalone Distribution

When distributing as a standalone addon, create a standard `.toc` file and register the slash command automatically:

```lua
-- In your standalone ADDON_LOADED handler
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, _, addonName)
    if addonName == "AceCommQueue-1.0" then
        LibStub("AceCommQueue-1.0"):RegisterSlashCommand("/acq")
        -- Optionally read a SavedVariables key here and call SetDebug accordingly
    end
end)
```

When shipped embedded inside another addon's `Libs` folder, do not register the slash command from the library file itself — let the host addon decide whether and with what command to register it.

## LibStub Versioning

The library follows LibStub's upgrade semantics. The `MINOR` integer is bumped with each revision during development. The highest-`MINOR` copy loaded wins; older copies loaded afterward are silently discarded. The library name (`AceCommQueue-1.0`) does not change between revisions — only between breaking API changes.

Per-queue state (`queues` table) and the `debug` flag are preserved across LibStub upgrades within the same WoW session.
