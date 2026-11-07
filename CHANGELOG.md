# Changelog

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
