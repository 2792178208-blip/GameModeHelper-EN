# Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-10-25

### Changed

- **Main-window app**: replaced menu-bar-resident with a standard window (Dock icon, ⌘Q /
  close-to-quit, quit confirmation and logging retained); panel features unchanged
- **DMG installer**: `./build.sh dmg` builds it in one step — open, drag into Applications, done
- Fixed a test leftover: stale game-mode flag in the LaunchServices database (restoring the
  plist without refreshing registration caused ZCode etc. to be repeatedly misidentified as a
  game); "Restore default" now refreshes the registration

## [1.1.0] - 2026-10-25

### Added

- **Game Mode launcher**: generate a declared stub app for Java/jar programs and bare
  executables (GameStub pattern — the runner registers as an app then execv's the target
  program; the PID inherits the game identity)
- **One-click HMCL integration**: the window lists running bare processes (java etc.); one
  click generates a wrapper and writes it into every HMCL instance's wrapper setting — supports
  both the new settings system (`instance-game-settings.json` + `overrideProperties` + global
  presets) and legacy `hmclversion.cfg`, all backed up and restorable; takes effect after an
  HMCL restart
- Passthrough mode (experimental): the stub runner can serve as a launcher's "custom Java"
- Runner diagnostic log (`~/Library/Logs/GameModeHelper/wrapper.log`)
- CLI `--auth-test` (admin authorization cache diagnostics)

### Fixed

- Enable failing on running apps: Sparkle-style copy-and-swap patching with automatic rollback
- Re-signing dropped sandbox entitlements → selectively preserves `com.apple.security.*`
- Repeated admin password prompts → one authorization reused within the session
- Read-only system volumes (Safari etc.) incorrectly prompting for a password → explicit refusal
- HMCL success message being clobbered by the list refresh, repeated clicks creating duplicate
  stubs → stable messaging + idempotent convergence to a fixed path
- Self-test hanging: the dummy app is quit gracefully before restore (fully prompt-free, 33 s)

### Known limitations

- Game identity is decided at process launch — running processes cannot be patched (restart
  the app/game)
- HMCL wiring requires an HMCL restart (its settings are only read at startup)
- Game Mode varies by game and machine; some games (e.g. Minecraft Java on certain machines)
  may perform worse with it on — ⌘Esc turns it off per app

## [1.0.0] - 2026-10-25

Initial public release.

### Added

- Adds the macOS Game Mode declaration to any app (`LSSupportsGameMode` / `GCSupportsGameMode`
  + games category) so native fullscreen triggers Game Mode automatically
- Panel lists running apps only, frontmost pinned and auto-selected; manual refresh (no
  background polling)
- "Choose App…" for apps that aren't running
- Copy-and-swap patching for running apps (Sparkle-style) with automatic rollback
- Re-signing selectively preserves `com.apple.security.*` entitlements — sandboxed apps keep
  their saves and settings
- One-click restore (original Info.plist from backup, re-signed); read-only system volume apps
  are refused with a clear message
- Admin authorization once per session (AuthorizationRef cache)
- Restart-to-apply: graceful quit with SIGTERM fallback (user-confirmed)
- Full logging (`~/Library/Logs/GameModeHelper/helper.log`)
- Built-in self test (15 checks) and end-to-end suite (6 checks): `./selftest.sh`
- Full CLI: `--list / --enable / --disable / --status / --restart / --selftest / --auth-test`
