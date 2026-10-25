# Contributing

Thanks for considering a contribution! Issues and pull requests are welcome.

## Development environment

- macOS 14+ (Apple Silicon recommended)
- Xcode Command Line Tools (`xcode-select --install`)

## Build & test

```bash
git clone <repository URL>
cd GameModeHelper
./build.sh           # build GameModeHelper.app
./selftest.sh        # 15 built-in + 6 end-to-end checks — must pass before every commit
./build.sh install   # install to ~/Applications (optional)
```

## Commit guidelines

- One PR per concern; explain *why*, not just what
- Behavior changes must update the README and CHANGELOG (Unreleased section)
- Commit messages in English or Chinese, imperative mood ("Fix xxx")

## Code conventions

- In-code comments and UI strings currently use Simplified Chinese (matching the existing
  style); documentation in this repository is English
- No third-party dependencies; system frameworks only
- Any logic that modifies user apps must preserve the safety discipline:
  1. Back up before touching anything, and keep everything one-click restorable
  2. Never quit or kill any process (restarts only after explicit user confirmation)
  3. Log every failure path and surface a clear message to the user
  4. The self test must cover new logic

## Reporting issues

Please include: macOS version, chip (Apple Silicon / Intel), the problematic app's name and
source (App Store / official site / CrossOver etc.), and the relevant lines from
`~/Library/Logs/GameModeHelper/helper.log`.
