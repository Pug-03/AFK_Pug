# Changelog

## Unreleased

### Added
- Update check once a day, with a card and one-click install. The download is checked before it's installed, and the check can be turned off.
- Optional time left or agent count beside the A in the menu bar.
- Early battery warning, 5 points above the floor.
- Liquid Glass cards on macOS 26, rolling timer digits and light trackpad taps.
- Demo animation in the README.
- Colors are picked right in Settings: swatches for the background and accent, plus a color pad and hex field.

### Fixed
- Phone messages now leave before a closed Mac goes to sleep.
- A finished agent is reported even when the Mac sleeps right away.
- The window stays still when you change pages, and its top stays on screen when a row goes away.
- Agent rows fade and slide when they come and go, and the window follows on the same curve instead of jumping.

### Changed
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
