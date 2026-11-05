#!/bin/bash
# 牛马续航小窗 一键安装（macOS）
# 用法：在「终端」里粘贴下面这行回车
#   curl -fsSL https://zhangruixiang999.github.io/work-countdown/download/install.sh | bash
#
# 为什么要用终端装：App 没有经过苹果付费公证。浏览器下载的文件会被打上「来自互联网」标记，
# macOS 15 及以后直接拦住不让打开（右键 → 打开 也不行了）。用 curl 下载不会打这个标记。
set -e

APP_NAME="牛马续航小窗"
ZIP_URL="${NIUXU_ZIP_URL:-https://zhangruixiang999.github.io/work-countdown/download/niuxu-mini-mac.zip}"
PAGE_URL="http://127.0.0.1:47821/"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "① 下载安装包…"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/app.zip"

echo "② 解压…"
ditto -x -k "$TMP/app.zip" "$TMP/x"
SRC="$(find "$TMP/x" -maxdepth 3 -name "$APP_NAME.app" -type d | head -1)"
if [ -z "$SRC" ]; then
  echo "❌ 安装包里没找到 $APP_NAME.app"
  exit 1
fi

echo "③ 安装到「应用程序」…"
pkill -f "$APP_NAME.app/Contents/MacOS/niuxu-mini" 2>/dev/null || true
sleep 0.5
DEST="${NIUXU_DEST:-/Applications}"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
rm -rf "$DEST/$APP_NAME.app"
ditto "$SRC" "$DEST/$APP_NAME.app"
xattr -cr "$DEST/$APP_NAME.app" 2>/dev/null || true

echo "④ 启动…"
open "$DEST/$APP_NAME.app"

for _ in $(seq 1 20); do
  if curl -fs "${PAGE_URL}ping" >/dev/null 2>&1; then
    [ -z "$NIUXU_NO_BROWSER" ] && open "$PAGE_URL"
    echo ""
    echo "✅ 装好了：$DEST/$APP_NAME.app"
    echo "   屏幕右上角是透明小窗，菜单栏有沙漏图标。"
    echo "   浏览器里打开的 $PAGE_URL 就是网页版，标签页留着（可以最小化）。"
    exit 0
  fi
  sleep 0.5
done

echo ""
echo "⚠️  App 已安装到 $DEST/$APP_NAME.app，但 10 秒内没检测到它启动。"
echo "   去「应用程序」里双击「$APP_NAME」试试；还不行就把这段输出截图发给作者。"
exit 1
