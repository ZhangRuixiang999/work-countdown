#!/bin/bash
# 编译「牛马续航小窗」.app，需要 macOS 命令行工具（swiftc）
set -e
cd "$(dirname "$0")"

APP="牛马续航小窗.app"
BIN="niuxu-mini"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

echo "编译中…"
swiftc -O -framework Cocoa -framework WebKit -framework Network main.swift -o "$APP/Contents/MacOS/$BIN"

# 本地自签名，避免「已损坏」提示
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "构建完成：$(pwd)/$APP"
echo "双击打开即可，菜单栏会出现沙漏图标。"
