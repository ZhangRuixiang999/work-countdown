#!/bin/bash
# 编译「牛马续航小窗」.app（通用二进制：Apple 芯片 + Intel 都能跑）
set -e
cd "$(dirname "$0")"

APP="牛马续航小窗.app"
BIN="niuxu-mini"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

echo "编译 arm64…"
swiftc -O -target arm64-apple-macos12 -framework Cocoa -framework WebKit -framework Network main.swift -o "$TMP/$BIN-arm64"

echo "编译 x86_64…"
if swiftc -O -target x86_64-apple-macos12 -framework Cocoa -framework WebKit -framework Network main.swift -o "$TMP/$BIN-x86_64" 2>/dev/null; then
  lipo -create "$TMP/$BIN-arm64" "$TMP/$BIN-x86_64" -output "$APP/Contents/MacOS/$BIN"
else
  echo "⚠️  x86_64 交叉编译失败，只打包当前架构"
  cp "$TMP/$BIN-arm64" "$APP/Contents/MacOS/$BIN"
fi
chmod +x "$APP/Contents/MacOS/$BIN"

# 本地自签名，避免「已损坏」提示
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "构建完成：$(pwd)/$APP"
echo "架构：$(lipo -archs "$APP/Contents/MacOS/$BIN" 2>/dev/null || echo unknown)"
echo "双击打开即可，菜单栏会出现沙漏图标。"
