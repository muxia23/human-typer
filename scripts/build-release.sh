#!/bin/bash
# 生成发布文件：build/release/human-typer-macos.zip 和 install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
STAGE="$OUT/human-typer"
SOURCES=("$ROOT/host/main.swift" "$ROOT/host/Core.swift")

rm -rf "$OUT"
mkdir -p "$STAGE"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12" "${SOURCES[@]}" -o "$OUT/host-$arch"
done
lipo -create "$OUT/host-arm64" "$OUT/host-x86_64" -output "$STAGE/human-typer-host"
codesign --force --sign - --identifier com.humantyper.host "$STAGE/human-typer-host"

cp -R "$ROOT/extension" "$STAGE/extension"
cp "$ROOT/scripts/uninstall.sh" "$ROOT/LICENSE" "$STAGE/"

(cd "$OUT" && zip -qry human-typer-macos.zip human-typer)
cp "$ROOT/scripts/install-release.sh" "$OUT/install.sh"
rm -rf "$STAGE" "$OUT"/host-*

ls -l "$OUT"
