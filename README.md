# GameModeHelper

[![build](https://github.com/2792178208-blip/GameModeHelper-EN/actions/workflows/build.yml/badge.svg)](../../actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](#requirements)
[![Platform](https://img.shields.io/badge/Apple%20Silicon-only-orange)](#requirements)

English ｜ **[中文版仓库 Chinese repository](https://github.com/2792178208-blip/GameModeHelper)**

> This is the **English edition** of GameModeHelper — same code, fully translated docs.
> The app interface is currently Simplified Chinese; everything else (docs, README, manual) is English.

A macOS desktop utility (main-window app) that adds the **Game Mode declaration to any app**, so macOS
automatically turns on **Game Mode** (CPU/GPU priority, reduced background activity, doubled
Bluetooth accessory polling rate) whenever the app runs in native fullscreen.

> Typical use cases: Windows games in CrossOver / Whisky / Parallels, emulators like RetroArch
> or OpenEmu, streaming clients like GeForce NOW, Minecraft (Java), older games that never
> declared themselves as games — macOS doesn't recognize them as games and never enables
> Game Mode for them. This tool fills that gap.

> ⚠️ **免责声明 / Disclaimer**
>
> This project is an **experimental tool built quickly in personal spare time**, not fully
> tested production software:
> - **Availability is NOT widely verified**: it was only tested on a single Apple Silicon Mac
>   (macOS 27) — not across the vast majority of machines, OS versions and app combinations
> - **Limited coverage**: verified for regular apps (.app bundles), jar/Java programs, and
>   Minecraft launched via HMCL; other launchers (PCL/Prism etc.) are theoretically possible
>   but unverified
> - **Unconventional operations**: modifying third-party apps' Info.plist and re-signing them
>   is unconventional — App Store apps lose store validation, some security software may
>   flag it, and some vendors may not support it
> - **This project is mainly provided as an idea / reference implementation** — how to use
>   Apple's public `LSSupportsGameMode` declaration mechanism to grant any program Game Mode
>   eligibility. Improvements are welcome
>
> Only use it on software you have the right to modify and have backed up, at your own risk;
> "Restore default" recovers the original state. Provided for learning and exchange, with no
> warranties of any kind. Respect the target software's license and local laws.

## How it works

macOS Game Mode is governed by the `gamepolicyd` daemon: when an app it classifies as a **game**
runs in **native fullscreen** (the ⌃⌘F fullscreen space), Game Mode turns on automatically.
Whether an app counts as a game comes from its `Info.plist` declaration — many games and
emulators never declare it, so they never get Game Mode.

This tool:

1. Writes `LSSupportsGameMode` (macOS 26+) / `GCSupportsGameMode` (macOS 14+, legacy — both
   written for compatibility) = `true` into the target app's `Info.plist`, plus the games category
2. Re-signs the app ad-hoc so it keeps launching (**selectively preserving
   `com.apple.security.*` entitlements** — sandboxed apps keep their containers and saves)
3. Refreshes the LaunchServices registration so the system picks up the change immediately

The effect is objectively verifiable in the system log — after enabling, `gamepolicyd` logs:

```
Found game GameProcess("your game", pid=…, labelReason=LSSupportsGameMode (Info.plist))
Gaming session is now active …
Game mode status is now on.        ← Game Mode officially on at fullscreen
Game mode status is now off.       ← automatically restored on quit
```

Full decision chain: `IdentifiedGameGrant` (from the declaration) → `FrontmostGrant` (foreground)
→ `FullScreenGrant` + `ConsoleModeGrant` (native fullscreen) → **Game Mode on**.

## Requirements

| | |
|---|---|
| Chip | Apple Silicon (Game Mode itself is unavailable on Intel Macs) |
| OS | macOS 14 Sonoma+ (14–15 via `GCSupportsGameMode`, 26+ via `LSSupportsGameMode` — this tool writes both) |
| Building | Xcode Command Line Tools (`xcode-select --install`) |

## Install

**Option A: download a packaged release** (see Releases)

1. Download `GameModeHelper-vX.Y.Z-macOS.dmg`, open it and drag `GameModeHelper.app` into the "Applications" folder
3. First launch: right-click the app → Open → Open (bypasses Gatekeeper; the app is not
   notarized), or run `xattr -cr /path/to/GameModeHelper.app`

**Option B: build from source**

```bash
git clone https://github.com/2792178208-blip/GameModeHelper-EN.git
cd GameModeHelper
./build.sh install   # build and install to ~/Applications
./selftest.sh        # optional: 12 built-in + 6 end-to-end checks
```

## Usage

1. Open "GameModeHelper" (standard window app with a Dock icon; ⌘Q or closing the window quits it)
2. The list **only shows running apps**; the frontmost app is pinned to the top, badged and
   auto-selected — start your game, open the panel, and it's usually already selected.
   Click "Refresh" (刷新) to re-detect
3. Click "开启游戏模式支持" (Enable Game Mode support); enter your password **once** when
   prompted — all further privileged operations in this session are silent
4. Click "重启 App 生效" (Restart app to apply) — asks for confirmation first; the declaration
   is read at process launch, so a restart is required
5. Whenever that app enters native fullscreen, macOS turns on Game Mode automatically.
   Press **⌘Esc** to open the system Game Overlay and check the mode state

See **[docs/USAGE.md](docs/USAGE.md)** for the detailed step-by-step manual (in Chinese).

## Java / jar / arbitrary programs: Game Mode launchers

Minecraft (HMCL/PCL), jar tools and bare executables have no app bundle, so the system can't
give them a game identity. This tool can wrap them into a declared stub app (GameStub pattern):

1. Click **"创建启动器…" (Create launcher…)** at the bottom of the panel
2. Fill in: name, program path (executable or `.jar` — automatically wrapped with `java -jar`),
   arguments, working directory
3. Click "创建" — a `~/Applications/<name>.app` is generated; double-click it to launch the
   target program with a game identity, and Game Mode turns on at fullscreen

### One-click HMCL integration (Game Mode for the Minecraft process itself)

A Minecraft process already spawned by HMCL cannot be added retroactively (identity is decided
at process launch — experimentally verified). But the flow is now **fully automatic**:

1. Start HMCL — the panel list shows it as a `java` entry badged "裸程序" (bare process)
2. Select it → click "开启游戏模式支持" (Enable Game Mode support)
3. Done. The tool automatically: generates a declared wrapper stub → points the `wrapper`
   field of every HMCL game instance at it (original configs backed up as `.gmhelper-bak`)
4. Launch games from HMCL as usual: HMCL now starts java through the wrapper, the game
   inherits a game identity, and Game Mode turns on at native fullscreen (⌃⌘F) — for every
   instance using that Java

How it works: HMCL's launch command becomes `<wrapper> <java> <game args>`; the wrapper
registers as a game and execs the real java — same PID, inherited identity (verified via
`gamepolicyd` logs: `Found game … labelReason=LSSupportsGameMode (Info.plist)` → fullscreen →
`Game mode status is now on.`). Restore: select the java entry and click "还原默认" to restore
all instance configs automatically.

Note: the wrapper needs ~0.5 s to register its identity, so HMCL's Java version probe becomes
slightly slower — normal; game output is unaffected.

## FAQ

**No Game Mode after fullscreen?** Check in order: ① did you click "Restart app to apply"
(the declaration needs a relaunch); ② is it **native fullscreen** (⌃⌘F) — borderless windows,
split screen and edge-snapping do NOT trigger; ③ is the app on the read-only system volume
(e.g. Safari — the tool marks it "系统卷" and refuses).

**Why must a running app be restarted after patching?** The system classifies a process **once,
at launch**. Verified via `gamepolicyd` logs: injecting the declaration into a running app and
refreshing LaunchServices does not re-classify the live process, even across fullscreen
transitions — that's a system constraint, not a limitation we chose.

**Does it affect normal app usage?** Only three keys in `Info.plist` are touched; resources are
untouched; re-signing preserves `com.apple.security.*` entitlements (sandboxed apps keep saves
and settings). One-click restore is always available. Note: App Store apps lose store
validation after re-signing (local use is unaffected).

**Will it touch my other programs?** No. It never quits or kills anything; the only restart is
the one app you explicitly confirm.

**How many times do I type my password?** Once for the first privileged operation — cached for
the whole app session. After an app restart you type it once more; to eliminate it entirely,
allow the tool under System Settings → Privacy & Security → **App Management**.

**Borderless fullscreen?** Not supported — macOS only triggers Game Mode in native fullscreen
spaces.

## Command line

```bash
BIN=GameModeHelper.app/Contents/MacOS/GameModeHelper
$BIN --list                  # list installed apps and their Game Mode state
$BIN --enable <path|bundleID>
$BIN --disable <path|bundleID>
$BIN --status <path|bundleID>
$BIN --restart <path|bundleID>
$BIN --selftest [--dummy <path>]
$BIN --auth-test             # diagnose the admin authorization cache
```

## Restore & uninstall

- **Restore an app**: select it in the panel → "还原默认" (restores the original Info.plist and re-signs)
- **Uninstall the tool**: click "退出" (Quit) at the bottom of the panel first, then:

```bash
mv ~/Applications/GameModeHelper.app ~/.Trash/
rm -rf ~/Library/Application\ Support/GameModeHelper ~/Library/Logs/GameModeHelper
```

(Restore patched apps first; you can also reinstall the tool later to restore them.)

## Privacy & security

- No network access, no data collection — everything runs locally
- Full log at `~/Library/Logs/GameModeHelper/helper.log`
- Fully open source, no obfuscation, no third-party dependencies — build and audit it yourself

## Known limitations

- Game Mode itself is unavailable on Intel Macs
- A running app **must be restarted** after patching (system mechanism, experimentally verified)
- Apps on the read-only system volume (e.g. Safari) cannot be modified
- Borderless fullscreen does not trigger Game Mode — a hard system requirement

## Acknowledgments

- [Apple docs: LSSupportsGameMode](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode) ·
  [WWDC25 "Level up your games"](https://developer.apple.com/videos/play/wwdc2025/209)
- [nickzman/BetterGameMode](https://github.com/nickzman/BetterGameMode) — prior art built on
  Xcode's gamepolicyctl (system-wide switch); this tool uses the public Info.plist mechanism
- [CeciliaStudio/MinecraftGameStub](https://github.com/CeciliaStudio/MinecraftGameStub) — the
  wrapper + execv pattern for launch-time game identity (MIT)
- [Apple Support: Use Game Mode](https://support.apple.com/en-us/105118)

## License

[MIT](LICENSE)
