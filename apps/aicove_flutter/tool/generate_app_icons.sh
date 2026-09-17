#!/bin/bash
# 从 tool/app_icon_1024.png（1024x1024 母图）生成全平台应用图标。
# 用法：tool/generate_app_icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tool/app_icon_1024.png"

resize() { # resize <尺寸> <输出路径>
  sips -z "$1" "$1" "$SRC" --out "$2" >/dev/null
}

# macOS：Assets.xcassets/AppIcon.appiconset
MAC="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 64 128 256 512 1024; do
  resize "$s" "$MAC/app_icon_$s.png"
done

# iOS：Assets.xcassets/AppIcon.appiconset（文件名按 Contents.json 固定）
IOS="$ROOT/ios/Runner/Assets.xcassets/AppIcon.appiconset"
declare -a ios_map=(
  "Icon-App-20x20@1x.png:20" "Icon-App-20x20@2x.png:40" "Icon-App-20x20@3x.png:60"
  "Icon-App-29x29@1x.png:29" "Icon-App-29x29@2x.png:58" "Icon-App-29x29@3x.png:87"
  "Icon-App-40x40@1x.png:40" "Icon-App-40x40@2x.png:80" "Icon-App-40x40@3x.png:120"
  "Icon-App-60x60@2x.png:120" "Icon-App-60x60@3x.png:180"
  "Icon-App-76x76@1x.png:76" "Icon-App-76x76@2x.png:152"
  "Icon-App-83.5x83.5@2x.png:167" "Icon-App-1024x1024@1x.png:1024"
)
for entry in "${ios_map[@]}"; do
  resize "${entry##*:}" "$IOS/${entry%%:*}"
done

# Android：mipmap-*/ic_launcher.png
declare -a android_map=(mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192)
for entry in "${android_map[@]}"; do
  resize "${entry##*:}" "$ROOT/android/app/src/main/res/mipmap-${entry%%:*}/ic_launcher.png"
done

# Windows：resources/app_icon.ico（多尺寸 PNG 内嵌 ICO）
TMP_ICO="$(mktemp -d)"
trap 'rm -rf "$TMP_ICO"' EXIT
for s in 16 24 32 48 64 128 256; do
  resize "$s" "$TMP_ICO/$s.png"
done
python3 - "$TMP_ICO" "$ROOT/windows/runner/resources/app_icon.ico" <<'PY'
import os, struct, sys
src_dir, out = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
blobs = [open(os.path.join(src_dir, f"{s}.png"), "rb").read() for s in sizes]
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, blob in zip(sizes, blobs):
    dim = 0 if s == 256 else s
    entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(blob), offset)
    offset += len(blob)
open(out, "wb").write(header + entries + b"".join(blobs))
PY

echo "app icons generated from $SRC"
