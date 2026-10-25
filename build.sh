#!/bin/bash
# 构建「游戏模式助手」。只依赖 Xcode Command Line Tools。
# 用法：./build.sh           仅构建
#      ./build.sh install   构建并安装到 ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

MIN_MACOS="14.0"
APP="GameModeHelper.app"
SOURCES=(Sources/main.swift Sources/AppDelegate.swift Sources/HelperCore.swift
         Sources/PrivilegedRunner.swift Sources/StubGenerator.swift
         Sources/Models.swift Sources/PanelModel.swift Sources/PanelView.swift)

echo "==> 清理旧构建"
rm -rf build "$APP"
mkdir -p build

echo "==> 编译（arm64，macOS $MIN_MACOS+）"
swiftc -O -whole-module-optimization \
  -target "arm64-apple-macos$MIN_MACOS" \
  -o build/GameModeHelper "${SOURCES[@]}" \
  -framework Cocoa -framework SwiftUI -framework UserNotifications

echo "==> 编译游戏模式启动器运行器（GameStubRunner）"
swiftc -O -o build/GameStubRunner Sources/StubRunnerMain.swift -framework Cocoa

echo "==> 组装 App 包"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/GameModeHelper "$APP/Contents/MacOS/GameModeHelper"
cp build/GameStubRunner "$APP/Contents/Resources/GameStubRunner"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> 生成图标"
if [ ! -f build/GameModeHelper.icns ]; then
  swiftc -O -o build/makeicon Tools/makeicon.swift -framework Cocoa
  ./build/makeicon build/icon_1024.png
  mkdir -p build/icon.iconset
  sips -z 16 16     build/icon_1024.png --out build/icon.iconset/icon_16x16.png      >/dev/null
  sips -z 32 32     build/icon_1024.png --out build/icon.iconset/icon_16x16@2x.png   >/dev/null
  sips -z 32 32     build/icon_1024.png --out build/icon.iconset/icon_32x32.png      >/dev/null
  sips -z 64 64     build/icon_1024.png --out build/icon.iconset/icon_32x32@2x.png   >/dev/null
  sips -z 128 128   build/icon_1024.png --out build/icon.iconset/icon_128x128.png    >/dev/null
  sips -z 256 256   build/icon_1024.png --out build/icon.iconset/icon_128x128@2x.png >/dev/null
  sips -z 256 256   build/icon_1024.png --out build/icon.iconset/icon_256x256.png    >/dev/null
  sips -z 512 512   build/icon_1024.png --out build/icon.iconset/icon_256x256@2x.png >/dev/null
  sips -z 512 512   build/icon_1024.png --out build/icon.iconset/icon_512x512.png    >/dev/null
  sips -z 1024 1024 build/icon_1024.png --out build/icon.iconset/icon_512x512@2x.png >/dev/null
  iconutil -c icns build/icon.iconset -o build/GameModeHelper.icns
fi
cp build/GameModeHelper.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> 本地签名（ad-hoc）"
codesign --force --sign - "$APP"

if [ "${1:-}" = "install" ]; then
  echo "==> 安装到 ~/Applications"
  mkdir -p ~/Applications
  rm -rf ~/Applications/GameModeHelper.app
  cp -R "$APP" ~/Applications/
  echo "已安装：~/Applications/GameModeHelper.app"
fi

if [ "${1:-}" = "dmg" ]; then
  echo "==> 打包 DMG"
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
  DMG="GameModeHelper-v${VERSION}-macOS.dmg"
  STAGE=$(mktemp -d /tmp/gmh-dmg.XXXXXX)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "GameModeHelper" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "已生成：$DMG"
fi

echo "==> 完成：$APP"
