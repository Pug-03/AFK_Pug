# AFK Pug

Close the lid. Your agents keep running. AFK Pug keeps watch.

AFK Pug is a macOS menu bar app that keeps your MacBook awake while you're away, even with the lid closed and no external display. It's built for developers who start Claude Code (or any long job) and walk away.

## Features (v0.1)

**Keep awake**
- One-click "Go AFK" with timers: 30m, 1h, 2h, 4h, 8h, or until you stop. Add +30m while running.
- Lid-closed mode without an external display, on battery or power.
- Agent mode: stays awake only while your AI agents are working, then waits a short grace period (off / 2 / 5 / 15 min) and lets the Mac sleep.

**Battery friendly (when the lid closes)**
- Turns the built-in screen off, and keeps pushing it dark (Apple Silicon can leave it lit under the lid).
- Mutes sound and restores it when you open the lid.
- Turns on Low Power Mode on battery or when the Mac gets hot, and restores it afterwards.
- Optional: lid-closed mode only when plugged in.
- When the work finishes with the lid shut, the Mac goes to sleep right away.

**Safety**
- Battery floor (default 15%): stops and lets the Mac sleep.
- Critical heat: always stops.
- Crash-safe: a flag file plus a launchd watchdog restore normal lid sleep if AFK Pug quits or crashes. Restored again on next launch.
- Permission is a scoped sudoers rule that allows only `pmset -a disablesleep 0|1` and `pmset -a lowpowermode 0|1`. Removable from Settings.

**Agents**
- One-click Claude Code hook install (`UserPromptSubmit`, `Stop`, `Notification`, `SessionEnd`). Backs up `~/.claude/settings.json` first.
- Live list of working agents. Release any one manually.
- Notifications when an agent finishes or needs your input.
- Works with any tool via the CLI.

**Welcome back**
- Summary when you open the lid: time closed, battery used, agent turns finished, peak heat.

## CLI

Installed at `~/.afkpug/bin/afkpug` (add it to your PATH):

```sh
afkpug run -- npm run build      # keep awake while a command runs
afkpug hold --for 2h --reason "deploy"
afkpug release                   # drop CLI holds
afkpug status
```

## Build

```sh
scripts/build.sh            # builds dist/AFK Pug.app
scripts/build.sh --install  # also copies to /Applications and launches
```

Requires macOS 14+, Apple Silicon. Swift 5.10+.

## How it works

- Lid open: an IOKit `PreventUserIdleSystemSleep` assertion (same as `caffeinate -i`).
- Lid closed: `pmset -a disablesleep 1`, re-checked every few seconds and always paired with `disablesleep 0`.
- Agent state: hooks write small files to `~/.afkpug/holds` and `~/.afkpug/events`; the app polls every 2 s.

Keep the Mac on a hard, ventilated surface. Don't put it in a bag while it's awake.

## Roadmap

- Privileged helper (SMAppService) instead of sudoers
- Hooks for Codex, Cursor, Gemini CLI, OpenCode; process detection for others
- Pause chat apps (Slack, Discord) while the lid is closed
- PushPug integration: phone/desktop alerts when agents finish
- Wake before Claude usage limit resets
- Triggers (Wi-Fi, power, app running), global shortcut, lock on lid open
- MCP tool so agents can request a hold themselves
