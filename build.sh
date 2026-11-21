#!/bin/bash
# 构建「应用卸载器」——只依赖系统自带的 Swift 工具链（无需 Xcode 工程）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="AppUninstaller"
BUILD="$ROOT/.build"
APP="$ROOT/dist/应用卸载器.app"
CACHE="$BUILD/modulecache"
ARCH="$(uname -m)"

echo "==> 编译 Swift 源码 ($ARCH)"
mkdir -p "$BUILD" "$CACHE"
swiftc -O \
    -swift-version 5 \
    -module-cache-path "$CACHE" \
    -target "${ARCH}-apple-macos13.0" \
    "$ROOT"/Sources/*.swift \
    -o "$BUILD/$NAME"

echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Ad-hoc 签名"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "（签名失败，仍可运行）"

echo "==> 完成：$APP"
