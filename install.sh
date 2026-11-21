#!/bin/bash
# 把「应用卸载器」安装到 /Applications 并打开
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/dist/应用卸载器.app"
DEST="/Applications/应用卸载器.app"

if [ ! -d "$SRC" ]; then
    echo "找不到 $SRC，请先运行 ./build.sh"
    exit 1
fi

if [ -w /Applications ]; then
    TARGET="$DEST"
else
    TARGET="$HOME/Applications/应用卸载器.app"
    mkdir -p "$HOME/Applications"
fi

case "$TARGET" in
    /Applications/*|"$HOME"/Applications/*) ;;
    *) echo "目标路径异常，已中止：$TARGET"; exit 1 ;;
esac

if [ -d "$TARGET" ]; then
    echo "移除旧版本：$TARGET"
    rm -rf "$TARGET"
fi

echo "安装到：$TARGET"
cp -R "$SRC" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo "完成，正在打开…"
open "$TARGET"
