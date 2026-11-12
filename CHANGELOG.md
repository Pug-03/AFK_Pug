# Changelog

## Unreleased

### Added
- **The welcome tour explains the hustle chart:** a new page after "See what each agent is doing" shows the chart with a sample week, what solid and faint bars mean, and that waiting and usage limits don't count. Hover the bars or switch 24h and 7d to try it.
- **A ? on the hustle card** shows the same explanation on the home screen, for anyone who already went through the welcome.

### Changed
- The README demo is rendered at 2× and downsampled, so the app screen stays sharp when the camera zooms and slow moves no longer step pixel by pixel. The README image is now an animated AVIF at 60 fps and 1600 px (was a 30 fps, 960 px WebP), about 1.5 MB instead of 2 MB, with no stale blocks on slow fades. The MP4 is 1920 px (was 1280) and tagged BT.709 so browsers show the right colors.
- The README demo is shorter, 13.5 s instead of 21, and shows the app being used: a cursor clicks the A, points at a job, closes the summary, picks 2h and presses Go AFK, and the timer counts down. The laptop's front edge is now one solid piece.

## 0.8.0 - 2026-11-10

### Added
- **Hide the hustle chart:** Settings → Agents → Agent hustle chart. Hidden or not, the hours are still counted.
- **Usage limits:** a card on the home screen shows how much of each AI's quota is used, with bars for the 5-hour and weekly windows and when each resets. Bars turn amber at 80% and red at 95%, and AFK Pug notifies you once per window when it crosses them. Codex is read from `codex app-server`. For Claude Code, press **Show** (or the switch in Settings → Agents): AFK Pug adds a small tap in front of your status line that saves only the limits, and your own status line keeps printing as before. Turning it off puts your status line back exactly.
- **While you were away:** the hustle card shows how much of the agents' work happened while you were away (lid closed, or nobody at the Mac for 5 minutes). Bars show that part solid and the rest faint.
- **Waited for you:** how long agents sat waiting for your answer today, in amber once it passes a minute.
- **A menu bar icon that shows what's happening:** the A breathes while agents work, blinks orange while one waits for you, and shrinks into a ring that empties as the Mac counts down to sleep. It stays still with Reduce motion on.
- **Done, with a little cheer:** a job that just finished draws its tick in the list with a soft glow, the jobs count pops and this hour's bar flashes.

### Fixed
- A Claude Code turn that ended with only a Monitor running no longer keeps the Mac awake as if the agent were still working. A turn that leaves a background build drops its hold 3 minutes after the build goes quiet (was 15), so the countdown starts.
- **Keep music playing** no longer turns AFK on by itself while the lid is open. Any app holding the speaker open (a Safari tab, a muted video) used to count as music. macOS already stays awake while audio plays, so now music only counts when you close the lid on it.

## 0.7.1 - 2026-11-08

### Fixed
- Thai text writes **Agent** with a capital A, so the headline no longer starts with a lowercase word.

## 0.7.0 - 2026-11-08

### Added
- **Agent hustle** on the home screen: how long your agents worked today, how many steps they took and how many jobs they finished, with a bar chart for the last 24 hours or 7 days. Hover a bar for its numbers. Counted on your Mac only and kept for 8 days.

### Changed
- **Lid-closed mode**, **Keep the screen on** and **Keep music playing** moved to a new **Keep awake** section at the top of Settings, so the home screen shows only your agents and the chart.

## 0.6.1 - 2026-11-08

### Fixed
- The panel always opens on the agent list, even if it was closed on Settings.
- Red status text is more vivid, so warnings stand out.

## 0.6.0 - 2026-11-07

### Added
- Update check once a day, with a card and one-click install. The download is checked before it's installed, and the check can be turned off.
- Optional time left or agent count beside the A in the menu bar.
- Early battery warning, 5 points above the floor.
- Liquid Glass cards on macOS 26, rolling timer digits and light trackpad taps.
- A MacBook demo video in the README.
- A first-run tutorial: choose a language, then learn the app one part at a time.
- Each agent row shows its project, request and current step, and says when it's waiting for you. A **Just finished** list shows which jobs ended. Requests stay on your Mac and aren't sent to your phone.
- Click an agent row to go to its window: the exact tab in Terminal and iTerm2, the project's window in VS Code and Cursor when it's open, and the app itself elsewhere. macOS asks once before AFK Pug can control Terminal or iTerm2.
- Keep the screen on for agents: while they work, or 30 minutes or an hour after they finish. Only on the charger with the lid open.
- Colors are picked right in Settings: swatches for the background and accent, plus a color pad and hex field.

### Fixed
- Page changes and Settings scrolling no longer stutter when the pointer is customised in Accessibility settings.
- Phone messages now leave before a closed Mac goes to sleep.
- A finished agent is reported even when the Mac sleeps right away.
- A usage limit that reset just before midnight no longer lets the Mac sleep just after it.
- The home screen scrolls if it would be taller than the screen, and pickers stay readable when the app's look differs from macOS.
- The window stays still when you change pages, and its top stays on screen when a row goes away.
- Agent rows fade and slide when they come and go, and the window follows on the same curve instead of jumping.
- Reading audio and processes no longer blocks the main thread every few seconds, which could stutter animations.

### Changed
- Settings has no scrollbar over the switches; a soft fade at the bottom shows there's more.
- The panel is wider, and unfolds from the menu bar with a spring when it opens.
- New app icon: a white A on black.
- **Keep the screen on** moved to the home screen, because it changes from night to night.
- The defaults are now English, a black background and a white accent. This also applies if you updated and never chose a language or accent. White replaces red among the accent presets.
- The welcome opens once more after this update, and after a reinstall from a new version.
- The duration picker no longer dims while an agent works.
- A notification about an unanswered prompt under the lid says the Mac sleeps in about 15 minutes.
- **Sleep now** is now **Allow sleep**, because it stops keeping the Mac awake and leaves the sleeping to macOS.
- An agent dismissed with its × shows **Stopped watching**, not **Agents done**.

## 0.5.0 - 2026-11-06

### Added
- Appearance settings: background (match Mac, white, black or any color) and accent color. Text stays readable on every choice.
- Downloadable app in GitHub releases.
- Step-by-step README in English and Thai.

### Changed
- A simple A mark replaces the pug, in the app and the menu bar.

### Fixed
- The window no longer keeps empty space after a card or row goes away, and stays right under the menu bar.
- The agent name is no longer cut off while waiting for a usage limit.

## Earlier versions

See the [commit history](https://github.com/Pug-03/AFK_Pug/commits/main).
