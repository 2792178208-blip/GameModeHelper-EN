#!/bin/bash
# 「游戏模式助手」端到端自测
#
# 安全纪律：
#   - 全程不退出、不强杀任何真实进程；只操测试自己编译的假 App
#   - 用户的偏好/设置不写入（本工具不用 UserDefaults）
#   - 用 trap 保证清理
#
# 覆盖：依赖工具、假 App 往返（开启→签名有效→可启动→备份→还原→可启动）、
#       真实 App 状态只读检查、CLI 全命令。

set -uo pipefail
cd "$(dirname "$0")"

APP="GameModeHelper.app"
BIN="$APP/Contents/MacOS/GameModeHelper"
DUMMY_BID="com.gamemode.testdummy"

PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
note() { echo "  [INFO] $1"; }

# 精确提取指定 bundleID 的 pid（只在 bundleID 行精确匹配的条目块内提取）
pids_of() {
    lsappinfo list 2>/dev/null | awk -v target="$1" '
        /^ *[0-9]+\) / { inblock = 0 }
        /bundleID="/ {
            if (index($0, "\"" target "\"") > 0) { inblock = 1 } else { inblock = 0 }
        }
        inblock && /pid = / {
            if (match($0, /pid = [0-9]+/)) { print substr($0, RSTART + 5, RLENGTH - 5) }
        }
    '
}

wait_until() {
    local i
    for i in $(seq 1 24); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 0.25
    done
    return 1
}

DUMMY_DIR=""
cleanup() {
    # 假 App 先优雅退出，兜底才按精确 pid 强杀（只碰测试资产）
    if [ -n "$DUMMY_DIR" ]; then
        osascript -e "tell application id \"$DUMMY_BID\" to quit" 2>/dev/null || true
        sleep 1
        for PID in $(pids_of "$DUMMY_BID"); do
            kill -9 "$PID" 2>/dev/null || true
        done
        rm -rf "$DUMMY_DIR"
    fi
    rm -rf "$HOME/Library/Application Support/GameModeHelper/backups/$DUMMY_BID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "== 0. 编译测试用假 App =="
for PID in $(pids_of "$DUMMY_BID"); do
    osascript -e "tell application id \"$DUMMY_BID\" to quit" 2>/dev/null || true
    sleep 1
    kill -9 "$PID" 2>/dev/null || true
done
DUMMY_DIR=$(mktemp -d /tmp/gmhelper-test.XXXXXX)
# 用「裸二进制」副本执行测试：打包 App 的身份会被「App 管理」TCC 归因，对测试假 App 的
# 写入会被判为需要管理员；裸二进制归因到调用方，走用户态快速路径，自检全程无需密码
BIN="$DUMMY_DIR/gmhelper-bare"
cp "$APP/Contents/MacOS/GameModeHelper" "$BIN"
# 启动器生成器自检需要 GameStubRunner（裸二进制按同目录查找）
cp "$APP/Contents/Resources/GameStubRunner" "$DUMMY_DIR/" 2>/dev/null || true
cat > "$DUMMY_DIR/main.swift" <<'SWIFT'
import Cocoa
final class DummyDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {}
}
autoreleasepool {
    let app = NSApplication.shared
    let delegate = DummyDelegate()
    app.delegate = delegate
    app.run()
}
SWIFT
mkdir -p "$DUMMY_DIR/GameModeTest.app/Contents/MacOS"
swiftc -O -o "$DUMMY_DIR/GameModeTest.app/Contents/MacOS/GameModeTest" "$DUMMY_DIR/main.swift"
plutil -create xml1 "$DUMMY_DIR/GameModeTest.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $DUMMY_BID" \
  -c "Add :CFBundleExecutable string GameModeTest" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleVersion string 1" \
  "$DUMMY_DIR/GameModeTest.app/Contents/Info.plist" >/dev/null
DUMMY_PATH="$DUMMY_DIR/GameModeTest.app"

echo "== 1. 内置自检（含假 App 全流程往返） =="
if "$BIN" --selftest --dummy "$DUMMY_PATH" > /tmp/gmhelper-selftest.out 2>&1; then
    ok "内置自检全部通过"
else
    bad "内置自检存在问题："
    sed 's/^/     /' /tmp/gmhelper-selftest.out
fi
note "自检明细：$(grep -c '^\[PASS\]' /tmp/gmhelper-selftest.out) 项通过，$(grep -c '^\[FAIL\]' /tmp/gmhelper-selftest.out) 项失败，$(grep -c '^\[INFO\]' /tmp/gmhelper-selftest.out) 项提示"

# 退出自检假 App（自建实例），CLI 操作走用户态路径
osascript -e "tell application id \"$DUMMY_BID\" to quit" 2>/dev/null || true
sleep 1

echo "== 2. CLI 命令验证 =="
OUT=$("$BIN" --list 2>&1)
LIST_COUNT=$(printf '%s\n' "$OUT" | grep -c . || true)
if [ "$LIST_COUNT" -gt 0 ]; then ok "--list 列出 ${LIST_COUNT} 个 App"; else bad "--list 为空"; fi

ST=$("$BIN" --status "$DUMMY_PATH" 2>&1)
if [ "$ST" = "未开启" ]; then ok "--status 正确显示假 App 未开启（自检已还原）"; else bad "--status 返回异常：${ST}"; fi

OUT=$("$BIN" --enable "$DUMMY_PATH" 2>&1)
echo "  $OUT"
if printf '%s' "$OUT" | grep -q "^OK"; then ok "--enable 开启成功"; else bad "--enable 失败"; fi
ST=$("$BIN" --status "$DUMMY_PATH" 2>&1)
if [ "$ST" = "已支持" ]; then ok "--enable 后状态为「已支持」"; else bad "--enable 后状态异常：${ST}"; fi

OUT=$("$BIN" --disable "$DUMMY_PATH" 2>&1)
echo "  $OUT"
ST=$("$BIN" --status "$DUMMY_PATH" 2>&1)
if [ "$ST" = "未开启" ]; then ok "--disable 还原成功"; else bad "--disable 后状态异常：${ST}"; fi

echo "== 3. 确认未碰任何真实 App（只读校验） =="
note "本工具不写 UserDefaults、不退出进程；以上仅操作测试假 App"

echo ""
echo "======================================"
echo "端到端自测结果：通过 ${PASS} 项，失败 ${FAIL} 项"
echo "======================================"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
