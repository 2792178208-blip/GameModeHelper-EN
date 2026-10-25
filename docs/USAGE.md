# GameModeHelper · User Manual

This manual covers day-to-day usage: every feature step by step, authorization, troubleshooting,
and uninstalling. For how it works internally, see the project [README](../README.md).

---

## 1. Requirements

| Check | Details |
|---|---|
| Mac | Apple Silicon (M1/M2/M3/M4; Game Mode itself is unavailable on Intel Macs) |
| System | macOS 14 Sonoma or later |
| Games | Any app that doesn't get Game Mode when fullscreened |

> Terminology: **native fullscreen** means fullscreen via ⌃⌘F or the window's green button
> (the whole screen is taken over and the menu bar hides). macOS only triggers Game Mode in
> native fullscreen — borderless windows, split view and edge-snapping do NOT count.

## 2. Install & first launch

1. Download `GameModeHelper-vX.Y.Z-macOS.dmg` from GitHub Releases and open it
2. Drag `GameModeHelper.app` from the left into the "Applications" folder on the right
3. First launch: right-click the app → Open → Open (bypasses Gatekeeper; the app is not
   notarized), or run `xattr -cr /Applications/GameModeHelper.app`

**Opening it**: launch "GameModeHelper" from Launchpad or the Applications folder. It's a
standard window app with a Dock icon — ⌘Q or the window's close button quits it (wiring and
backups stay on disk; reopen anytime).

## 3. Enable Game Mode for an app (core flow)

1. **Start your game first** (so it's running)
2. Open the GameModeHelper window
3. The list **only shows running apps**:
   - The frontmost app is pinned to the top, badged, and auto-selected
   - If your game isn't listed (not started yet), click "选择 App…" (Choose App…) to pick any
     `.app` manually
   - The list is not live — click "刷新" (Refresh) to re-detect
4. With the game selected, click **"开启游戏模式支持" (Enable Game Mode support)**
   - Enter your password once when prompted — further privileged operations this session are silent
   - "✅" means success; failures show the specific reason
5. Click **"重启 App 生效" (Restart app to apply)** and confirm
   - Why a restart is required: the system decides an app's "game identity" once, at process
     launch — patching a running process has no effect (experimentally verified)
   - The app quits gracefully and reopens (only that app; save your work first)
6. Switch the game to **native fullscreen** (⌃⌘F or the green button) — macOS turns on Game Mode
7. Verify: press **⌘Esc** to open the system Game Overlay and check the mode state

## 4. Java / jar / any program: create a Game Mode launcher

Minecraft (via HMCL/PCL), jar tools and bare executables have **no app bundle**, so the system
can't give them a game identity. Solution: generate a **declared stub app** for them.

**Steps**:

1. Click **"创建启动器…" (Create launcher…)** at the bottom of the window
2. Fill in:
   - **Name**: the stub app's display name (e.g. "Minecraft Game Mode")
   - **Program**: an executable path, or a `.jar` file (jar is wrapped with `java -jar`
     automatically; Java path auto-detected)
   - **Arguments**: launch arguments (optional)
   - **Working directory**: optional, defaults to the program's folder
3. Click "创建" (Create) → the stub appears at `~/Applications/<name>.app`
4. **Double-click the stub** to launch the target program — it carries a game identity from
   birth, and native fullscreen triggers Game Mode

**How it works**: the stub app carries the game declaration; its runner registers as an app,
then replaces its own process image (execv) with the real program — same PID, inherited
identity. Verified in `gamepolicyd` logs.

## 5. HMCL one-click integration (Game Mode for Minecraft itself)

A Minecraft process already spawned by HMCL cannot gain a game identity retroactively (identity
is decided at process launch). But the flow is **fully automatic**:

1. Start HMCL — the list shows it as a `java` entry badged "裸程序" (bare process)
2. Select it → click "开启游戏模式支持" — the tool automatically generates a wrapper stub and
   points the wrapper setting of **every HMCL game instance** at it (original configs are backed
   up as `.gmhelper-bak`, restorable any time)
3. **Completely quit and reopen HMCL** (HMCL reads settings only at startup), then launch the
   game as usual — HMCL now starts java through the wrapper, and the game inherits a game identity
4. Switch to **native fullscreen** (⌃⌘F / green button) → Game Mode turns on; ⌘Esc shows the state

Notes: the wrapper needs ~0.5 s to register its identity (HMCL's Java probe gets slightly
slower — normal). The **currently running game session** is unaffected — restart the game.
If the game's in-game "fullscreen" option is borderless, use system fullscreen instead.
To undo: select the java entry and click "还原默认" (Restore default) — all instance configs
are restored automatically.

## 6. Restore (turn Game Mode support off for an app)

1. Select the app in the window (state shows "已具备游戏模式资格" — supports Game Mode)
2. Click **"还原默认" (Restore default)** — the original Info.plist is restored from backup and
   the app is re-signed
3. Restart that app — it's fully back to stock

> On first enable, the original Info.plist is backed up to
> `~/Library/Application Support/GameModeHelper/backups/<bundleID>/` — restore always works.

## 7. Status badges

| Badge | Meaning |
|---|---|
| 前台 (Frontmost) | The app you're currently using — usually your game; auto-selected |
| 裸程序 (Bare process) | A running program without an app bundle (java / HMCL / Minecraft) |
| 系统卷 (System volume) | SIP-protected system app (e.g. Safari) — cannot be modified |
| 已具备游戏模式资格 / 还没有游戏模式声明 | Whether the app currently declares Game Mode support |

## 8. Command line

```bash
BIN=/Applications/GameModeHelper.app/Contents/MacOS/GameModeHelper
$BIN --list                          # list installed apps and states
$BIN --enable "/Applications/X.app"  # enable
$BIN --disable "/Applications/X.app" # restore
$BIN --status com.example.x          # query by bundle ID
$BIN --restart com.example.x         # restart that app
$BIN --selftest                      # built-in self test
$BIN --auth-test                     # admin authorization diagnostics
```

## 9. Troubleshooting

**Fullscreen but no Game Mode?** ① Did you click "Restart app to apply"? ② Is it native
fullscreen (⌃⌘F), not borderless? ③ Does the state show "已具备游戏模式资格"? ④ Check the logs:

```bash
grep "Found game" ~/Library/Logs/GameModeHelper/helper.log
/usr/bin/log show --last 10m --predicate 'process == "gamepolicyd"' --info | grep "Found game"
```

**Game Mode made my game laggy?** Game Mode's scheduling (performance locking, high refresh)
can be a net negative for some games/machines (verified case: Minecraft Java on one machine).
That's the system's behavior, not a tool bug — press **⌘Esc** and turn Game Mode off for that
app (remembered per app), or "Restore default" to remove the declaration entirely.

**"Admin operation failed" on enable?** Check the last line of
`~/Library/Logs/GameModeHelper/helper.log`; usually the password prompt was cancelled or disk
space ran out. Just retry.

**App Store game re-signed?** Local launching is unaffected; store validation/auto-update is
lost until you "Restore default" and update.

**Restart failed ("重启未完成")?** The app refused to quit (unsaved-changes dialog). Save and
quit it manually, then retry, or use `--restart` (falls back to SIGTERM).

**Enable a game that isn't running?** Click "选择 App…" and pick the `.app` directly — no need
to run it first.

**Where's the Game Mode toggle in System Settings?** There is no global switch. The per-app
Game Mode row in System Settings → Gaming appears **only while an app with a game identity is
running** — the system's game list is transient. Use ⌘Esc in fullscreen instead; same effect.

## 10. Logs

- Location: `~/Library/Logs/GameModeHelper/helper.log` (the "打开日志" button opens it)
- Records: every enable/restore with method and result, backups, authorizations, self tests,
  wrapper invocations (`wrapper.log`)
- Attach relevant lines when filing issues (redact personal info in paths)

## 11. Uninstall

1. "还原默认" (Restore default) for every app you enabled (important: backups are deleted with
   the tool)
2. Quit the app: click "退出" (Quit) at the bottom of the window
3. Remove the files:

```bash
mv /Applications/GameModeHelper.app ~/.Trash/
rm -rf ~/Library/Application\ Support/GameModeHelper ~/Library/Logs/GameModeHelper
```

---

Still stuck? Open an [issue](https://github.com/2792178208-blip/GameModeHelper-EN/issues) with
your macOS version, chip, app name and log excerpt.
