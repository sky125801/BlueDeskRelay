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

# 用固定的开发证书签名，不要用 ad-hoc：
# ad-hoc 签名没有稳定身份，系统的「辅助功能」授权是按 cdhash 记的，
# 每次编译 cdhash 都会变，授权随之失效（表现为每次启动都要重新申请权限）。
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$SIGN_ID" ]; then
    echo "==> 签名：$SIGN_ID"
    codesign --force --sign "$SIGN_ID" "$APP_DIR" >/dev/null 2>&1 \
        || codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
else
    echo "==> 未找到开发证书，回退 ad-hoc 签名（辅助功能授权会在重新编译后失效）"
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "==> 完成：$(pwd)/$APP_DIR"
echo "    双击运行，或复制到 /Applications 与 登录项。"
