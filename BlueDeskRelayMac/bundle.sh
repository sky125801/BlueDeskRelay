#!/bin/bash
# 把 swift build 的可执行文件打包成 BlueDesk Relay.app
# 用法：./bundle.sh   （产物在当前目录 ./BlueDesk Relay.app）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BlueDesk Relay"
APP_DIR="$APP_NAME.app"
BIN=".build/release/BlueDeskRelayMac"

echo "==> swift build -c release"
swift build -c release

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/BlueDeskRelayMac"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# 多语言：系统权限弹窗与 Finder 服务名走 lproj（UI 文案内嵌在 Swift 里）
echo "==> 拷贝本地化资源"
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP_DIR/Contents/Resources/"
done

codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> 完成：$(pwd)/$APP_DIR"
echo "    双击运行，或复制到 /Applications 与 登录项。"
