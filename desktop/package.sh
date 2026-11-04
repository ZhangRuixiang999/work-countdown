#!/bin/bash
# 打出可以直接发给别人安装的 zip：App + 安装说明
set -e
cd "$(dirname "$0")"

APP="牛马续航小窗.app"
ZIP="牛马续航小窗-mac.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

./build.sh

echo "打包…"
mkdir -p "$STAGE/牛马续航小窗"
cp -R "$APP" "$STAGE/牛马续航小窗/"
cp 安装说明.txt "$STAGE/牛马续航小窗/"
# ditto 会保留签名、执行权限和中文文件名
ditto -c -k --sequesterRsrc --keepParent "$STAGE/牛马续航小窗" "$ZIP.tmp"
mv "$ZIP.tmp" "$ZIP"

echo "完成：$(pwd)/$ZIP"
du -h "$ZIP"
