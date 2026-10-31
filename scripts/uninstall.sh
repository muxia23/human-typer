#!/bin/bash
set -euo pipefail

HOST_NAME="com.humantyper.host"

rm -f "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$HOST_NAME.json"
rm -f "$HOME/Library/Application Support/Arc/User Data/NativeMessagingHosts/$HOST_NAME.json"
rm -rf "$HOME/HumanTyper"

cat <<EOF
已删除本地程序和注册信息。还需要手动完成：
1. 在浏览器扩展页面移除 Human Typer。
2. 在“系统设置 → 隐私与安全性 → 辅助功能”中删除 human-typer-host。
EOF
