#!/bin/bash
# 核对 / 更新 Vendor/MaaCore 的头文件和 .tbd 存根，让它们跟上 maa-cli 装的 MaaCore。
#
#   tools/sync-maacore.sh          只核对：打印差异，有差异退出码 1
#   tools/sync-maacore.sh --write  把差异写进 Vendor/MaaCore（之后要重新编译，并人工看 AsstCallerExtra.h 的 diff）
#
# 只读 maa-cli 的安装（`maa version`、`nm`），不跑 update / install。头文件从 GitHub 上对应 tag 取（要 gh）。
set -euo pipefail

cd "$(dirname "$0")/.."
VENDOR=Vendor/MaaCore
LIB="$HOME/Library/Application Support/com.loong.maa/lib/libMaaCore.dylib"
WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

core_version=$(MAA_CONFIG_DIR="$HOME/.config/maa-cli" maa version maa-core 2>/dev/null | awk '/MaaCore/ {print $2}')
if [[ -z "$core_version" ]]; then
    echo "读不到 maa-cli 的 MaaCore 版本（maa version maa-core）" >&2
    exit 2
fi
pinned=$(cat "$VENDOR/PINNED_VERSION")
echo "maa-cli MaaCore: $core_version    头文件钉住: $pinned"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/include"
for f in AsstCaller.h AsstCallerExtra.h AsstPort.h MaaCore.h; do
    gh api "repos/MaaAssistantArknights/MaaAssistantArknights/contents/include/$f?ref=$core_version" \
        -H 'Accept: application/vnd.github.raw' > "$tmp/include/$f"
done
# modulemap 不跟上游：上游那份带 link 行，这里链接交给 -weak-lMaaCore。
cp "$VENDOR/include/module.modulemap" "$tmp/include/module.modulemap"

symbols=$(nm -gU "$LIB" | awk '$3 ~ /^_Asst/ {print $3}' | sort -u | paste -sd, - | sed 's/,/, /g')
mkdir -p "$tmp/lib"
cat > "$tmp/lib/libMaaCore.tbd" <<EOF
--- !tapi-tbd
tbd-version:     4
targets:         [ x86_64-macos, arm64-macos ]
install-name:    '@rpath/libMaaCore.dylib'
current-version: 0
compatibility-version: 0
exports:
  - targets:         [ x86_64-macos, arm64-macos ]
    symbols:         [ $symbols ]
...
EOF

changed=0
diff -ru "$VENDOR/include" "$tmp/include" || changed=1
diff -u "$VENDOR/lib/libMaaCore.tbd" "$tmp/lib/libMaaCore.tbd" || changed=1
[[ "$pinned" == "$core_version" ]] || changed=1

if [[ $changed -eq 0 ]]; then
    echo "一致，无需更新。"
    exit 0
fi
if [[ $WRITE -eq 0 ]]; then
    echo "有差异。确认后用 --write 写入；AsstCallerExtra.h 变了要重点看（实验接口，结构体布局变了会静默读错内存）。"
    exit 1
fi
cp "$tmp/include/"*.h "$VENDOR/include/"
cp "$tmp/lib/libMaaCore.tbd" "$VENDOR/lib/libMaaCore.tbd"
echo "$core_version" > "$VENDOR/PINNED_VERSION"
sed -i '' "s/static let pinnedHeaderVersion = \".*\"/static let pinnedHeaderVersion = \"$core_version\"/" MeoAsstMac/Remote/CorePreflight.swift
echo "已写入 $core_version。重新编译 Release 验证。"
