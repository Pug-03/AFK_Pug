<p align="center">
  <img src="docs/icon.png" width="128" alt="AFK Pug app icon">
</p>

<h1 align="center">AFK Pug</h1>

<p align="center">
  <b>Close the lid. Your agents keep running. AFK Pug keeps watch.</b>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-111111">
  <img alt="Swift 5.10+" src="https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-0A84FF">
  <img alt="Thai and English" src="https://img.shields.io/badge/lang-ไทย%20%C2%B7%20English-F9A15A">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#works-with-your-agents">Agents</a> ·
  <a href="#safety">Safety</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="README.th.md">ภาษาไทย</a>
</p>

---

You ask Claude Code to refactor a module, close your MacBook, and walk to lunch. When you come back, nothing happened: the Mac went to sleep the moment the lid shut.

**AFK Pug** is a tiny menu bar app that keeps your MacBook awake with the lid closed, with no external display, on battery or power. It knows when your AI agents are actually working, turns the screen off so the battery lasts, and lets the Mac sleep again as soon as the work is done.

<p align="center">
  <img src="docs/screenshot-en.png" width="340" alt="AFK Pug popover in English">
  &nbsp;&nbsp;
  <img src="docs/screenshot-th.png" width="340" alt="AFK Pug popover in Thai">
</p>

## Features

### Stay awake, lid closed
- **One click.** Pick 30m, 1h, 2h, 4h, 8h or ∞ and press **Go AFK**. Add 30 minutes or stop at any time.
- **No monitor, no dongle.** Works with the lid closed on battery or on power.
- **Shortcut.** <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>A</kbd> starts or stops AFK from any app.

### Knows when your agents work
- **Agent mode.** Awake only while Claude Code (or another agent) is working. An idle session at the prompt doesn't count, so the Mac sleeps normally.
- **Grace period.** Waits 2, 5 or 15 minutes after the last agent finishes, in case you send another prompt.
- **Notifications.** Tells you when an agent finishes or is waiting for you. Optional push to your phone through [ntfy](https://ntfy.sh).

### Easy on the battery
When the lid closes, AFK Pug:
- turns the built-in screen off (and keeps it off, since Apple Silicon can leave it lit under the lid),
- mutes sound, unless music is playing,
- turns on Low Power Mode on battery,
- can pause chat apps such as Slack, Discord and LINE,
- locks the screen so nobody can use your Mac while you're away.

Everything is put back when you open the lid, along with a short **"While you were away"** summary: time closed, battery used, agent turns finished and peak temperature.

### Music keeps playing
YouTube, Spotify or Apple Music playing? AFK Pug notices the audio and keeps the Mac awake with the sound on, even if you didn't press Go AFK.

### Starts by itself
- when the charger is connected,
- while apps you choose are open (for example `Xcode, Docker, OBS`).

### Speaks your language
Thai and English, switchable in Settings. Follows your macOS language by default.

## Install

AFK Pug isn't on the App Store yet. Build it from source:

```sh
git clone https://github.com/Pug-03/AKF_Pug.git
cd AKF_Pug
scripts/build.sh --install   # builds, copies to /Applications and launches
```

Requirements: an Apple Silicon MacBook, macOS 14 or later, and Xcode or the Swift 5.10+ toolchain.

The app is ad-hoc signed. If macOS blocks it the first time, open **System Settings → Privacy & Security** and choose **Open Anyway**.

## Quick start

1. Click the pug in the menu bar.
2. Next to **Lid-closed mode**, press **Set up** and enter your password once.
3. Press **Connect** to link Claude Code.
4. Start a task in Claude Code and close the lid.

If you use Amphetamine or a similar app, quit it so the two don't fight over sleep.

## Works with your agents

| Agent | How AFK Pug knows it's working |
|---|---|
| Claude Code | Lifecycle hooks (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification`, `SessionEnd`), installed in one click. A hold with no activity for 15 minutes is dropped, unless Claude's process is still busy |
| Codex, Gemini CLI, Cursor Agent, Aider, OpenCode, Amp, Goose, Qwen Code | Process detection: counts as working while the process tree uses CPU |
| Anything else | The `afkpug` command line tool |

### Command line

The CLI is installed at `~/.afkpug/bin/afkpug`.

```sh
afkpug run -- npm run build              # keep awake while a command runs
afkpug hold --for 2h --reason "deploy"   # keep awake for a while
afkpug release                           # drop CLI holds
afkpug status                            # what's keeping the Mac awake
```

### Let the agent ask (MCP)

Under **Settings → Agents → Let agents keep the Mac awake**, AFK Pug registers an MCP server with Claude Code. The agent then gets three tools:

| Tool | What it does |
|---|---|
| `keep_mac_awake` | Stay awake for 1–720 minutes, with a reason |
| `release_mac_awake` | Drop the holds it created |
| `afk_status` | List what's keeping the Mac awake |

Useful when a build or deploy keeps running after the agent's reply.

## Safety

A closed MacBook that keeps working sheds heat more slowly, so AFK Pug has several guards:

- **Battery floor.** Stops at 15% on battery (adjustable from 5% to 50%) and lets the Mac sleep.
- **Heat.** Turns on Low Power Mode when the Mac gets hot and always stops at critical temperature. This guard can't be turned off.
- **Crash-safe.** If the app quits or crashes, a launchd watchdog restores normal lid sleep within 30 seconds and resumes any paused apps. The next launch checks again.
- **Narrow permission.** The one-time setup adds a sudoers rule for exactly six commands: `pmset -a disablesleep 0|1`, and `pmset -b|-c lowpowermode 0|1` for the current power source only, so your own Low Power Mode settings are kept. Remove it any time from Settings.

Keep the Mac on a hard, ventilated surface. Don't put it in a bag while it's awake.

## How it works

| Situation | Mechanism |
|---|---|
| Lid open | IOKit `PreventUserIdleSystemSleep` assertion, the same thing `caffeinate -i` uses |
| Lid closed | `pmset -a disablesleep 1`, re-checked every few seconds and always paired with `disablesleep 0` |
| Agent state | Hooks write small files to `~/.afkpug/holds` and `~/.afkpug/events`. The app polls every 2 seconds |
| Music | CoreAudio reports whether the default output device is in use |
| Screen off | `pmset displaysleepnow`, repeated while the lid stays closed |

`caffeinate` alone isn't enough: closing a MacBook lid triggers a separate sleep path that idle-sleep assertions don't block.

## FAQ

<details>
<summary><b>Does the internet stay connected with the lid closed?</b></summary>
<br>
The Mac doesn't go to sleep, so Wi-Fi normally stays connected and downloads, SSH and syncs keep going. A weak connection, such as a phone hotspot, can still drop on its own.
</details>

<details>
<summary><b>How is this different from Amphetamine?</b></summary>
<br>
Amphetamine keeps the Mac awake for a set time. AFK Pug also turns the screen off and mutes sound when the lid closes, knows whether your agents are working, and lets the Mac sleep as soon as they're done.
</details>

<details>
<summary><b>What if I forget to turn it off?</b></summary>
<br>
Timers end on their own, agent mode ends when the work does, and quitting the app restores normal sleep. If the app crashes, the watchdog restores it within 30 seconds.
</details>

<details>
<summary><b>Does it send any data anywhere?</b></summary>
<br>
No. Everything stays on your Mac. The only network request is the optional phone notification, which goes to the ntfy topic you enter.
</details>

## Roadmap

- [ ] Signed and notarized release download
- [ ] Privileged helper (SMAppService) instead of a sudoers rule
- [ ] Native hooks for Codex, Cursor and Gemini CLI
- [ ] Wake the Mac shortly before a Claude usage limit resets
- [ ] PushPug integration

## Project layout

```
Sources/AFKPug/
├── App.swift           entry point, menu bar, --mcp and render modes
├── Engine.swift        session logic: timers, agents, guards, lid actions
├── PowerControl.swift  pmset, IOKit assertions, one-time setup
├── Sensors.swift       lid, battery and thermal state
├── Agents.swift        holds, events, Claude Code hooks, watchdog
├── Extras.swift        process detection, chat pause, lock, hotkey, ntfy, MCP, audio
├── Scripts.swift       hook, CLI and watchdog shell scripts
├── Views.swift         home screen
├── Settings.swift      settings screen and shared controls
├── PugArt.swift        the pug, app icon and menu bar icon
└── L10n.swift          Thai and English strings
```

## Credits

Made by [Pug-03](https://github.com/Pug-03), who also made [PushPug](https://github.com/Pug-03/PushPug). The pug is drawn entirely in SwiftUI.
