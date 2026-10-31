#!/bin/bash
# 在临时 HOME 中验证安装和卸载。参数：install.sh 路径；可选第二个参数为本地 zip，用于替代下载。
set -euo pipefail

INSTALLER="$1"
LOCAL_ZIP="${2:-}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
STUBS="$SANDBOX/stubs"
mkdir -p "$HOME/Library/Application Support/Google/Chrome" "$STUBS"

printf '#!/bin/bash\necho "$@" >> "%s/open.log"\n' "$SANDBOX" > "$STUBS/open"
chmod +x "$STUBS/open"
if [ -n "$LOCAL_ZIP" ]; then
  printf '#!/bin/bash\ncp "%s" "${@: -1}"\n' "$LOCAL_ZIP" > "$STUBS/curl"
  chmod +x "$STUBS/curl"
fi

PATH="$STUBS:$PATH" bash "$INSTALLER" > "$SANDBOX/output.log"

MANIFEST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.humantyper.host.json"
BINARY="$HOME/HumanTyper/human-typer-host"
node -e "
const m = JSON.parse(require('fs').readFileSync(process.argv[1]));
const id = require('fs').readFileSync(process.argv[2] + '/extension/extension-id.txt', 'utf8').trim();
if (m.path !== process.argv[2] + '/human-typer-host') throw new Error('path');
if (m.allowed_origins[0] !== 'chrome-extension://' + id + '/') throw new Error('origin');
" "$MANIFEST" "$HOME/HumanTyper"
echo "ok - 注册清单正确"

[ -x "$BINARY" ] && echo "ok - 本地程序可执行"
[ "$(lipo -archs "$BINARY")" = "x86_64 arm64" ] && echo "ok - 通用版本"
codesign --verify "$BINARY" && echo "ok - 签名有效"

RESPONSE="$(node -e "
const b = Buffer.from('{\"v\":2,\"cmd\":\"cancel\"}');
const h = Buffer.alloc(4);
h.writeUInt32LE(b.length);
process.stdout.write(Buffer.concat([h, b]));
" | "$BINARY" | tail -c +5 || true)"
case "$RESPONSE" in
  *unsupported_protocol*) echo "ok - 本地程序能响应协议" ;;
  *) echo "FAIL - 协议响应：$RESPONSE"; exit 1 ;;
esac

grep -q 'chrome://extensions' "$SANDBOX/open.log" && echo "ok - 打开了扩展页面"
grep -q 'HumanTyper/extension' "$SANDBOX/open.log" && echo "ok - 选中了扩展目录"

bash "$HOME/HumanTyper/uninstall.sh" > /dev/null
[ ! -e "$MANIFEST" ] && [ ! -e "$HOME/HumanTyper" ] && echo "ok - 卸载干净"
echo "all passed"
