#!/bin/bash
# 面向用户的一键安装：curl -fsSL <release>/install.sh | bash
set -euo pipefail

ZIP_URL="https://github.com/muxia23/human-typer/releases/latest/download/human-typer-macos.zip"
HOST_NAME="com.humantyper.host"
TARGET="$HOME/HumanTyper"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Human Typer 只支持 macOS。" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "正在下载 Human Typer..."
curl -fsSL "$ZIP_URL" -o "$WORK/human-typer.zip"
unzip -q "$WORK/human-typer.zip" -d "$WORK/unpacked"

rm -rf "$TARGET"
mkdir -p "$TARGET"
cp -R "$WORK/unpacked/human-typer/." "$TARGET/"

EXTENSION_ID="$(tr -d '[:space:]' < "$TARGET/extension/extension-id.txt")"
REGISTERED=0

register() {
  local browser_dir="$1"
  [ -d "$browser_dir" ] || return 0
  mkdir -p "$browser_dir/NativeMessagingHosts"
  cat > "$browser_dir/NativeMessagingHosts/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Human Typer native host",
  "path": "$TARGET/human-typer-host",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
EOF
  REGISTERED=1
}

register "$HOME/Library/Application Support/Google/Chrome"
register "$HOME/Library/Application Support/Arc/User Data"

if [ "$REGISTERED" -eq 0 ]; then
  echo "没有找到 Chrome 或 Arc，请先安装并打开一次浏览器，再重新运行安装命令。" >&2
  exit 1
fi

open -R "$TARGET/extension"
open -a "Google Chrome" "chrome://extensions" 2>/dev/null || true

cat <<EOF

安装完成，还差两步：

1. 在已打开的扩展页面开启“开发者模式”，把 Finder 中选中的 extension 文件夹拖进去，
   或点“加载已解压的扩展程序”选择它。
   如果页面没有自动打开，请在浏览器地址栏输入 chrome://extensions。
2. 第一次点开始时，按系统提示在“辅助功能”中允许 human-typer-host，然后再点一次开始。

卸载：bash "$TARGET/uninstall.sh"
EOF
