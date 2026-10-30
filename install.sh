#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="$ROOT/build/human-typer-host"
EXTENSION_ID="$(tr -d '[:space:]' < "$ROOT/extension/extension-id.txt")"
HOST_NAME="com.humantyper.host"

mkdir -p "$ROOT/build"
swiftc -O "$ROOT/host/main.swift" "$ROOT/host/Core.swift" -o "$BINARY"
codesign --force --sign - --identifier "$HOST_NAME" "$BINARY"

register() {
  local browser_dir="$1"
  if [ ! -d "$browser_dir" ]; then
    echo "skipped (not installed): $browser_dir"
    return 0
  fi
  mkdir -p "$browser_dir/NativeMessagingHosts"
  cat > "$browser_dir/NativeMessagingHosts/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Human Typer native host",
  "path": "$BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
EOF
  echo "registered: $browser_dir"
}

register "$HOME/Library/Application Support/Google/Chrome"
register "$HOME/Library/Application Support/Arc/User Data"
