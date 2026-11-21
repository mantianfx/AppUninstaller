#!/bin/bash
# 生成 AppIcon.icns（首次构建前运行一次即可）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
ICONSET="$BUILD/AppIcon.iconset"

mkdir -p "$BUILD/modulecache"
swiftc -O -module-cache-path "$BUILD/modulecache" "$ROOT/Scripts/make_icon.swift" -o "$BUILD/make_icon"
"$BUILD/make_icon" "$BUILD/icon-master.png"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$BUILD/icon-master.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$BUILD/icon-master.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
cp "$BUILD/icon-master.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "已生成 $ROOT/Resources/AppIcon.icns"
