#!/bin/zsh
# 앱 아이콘 만들기: 앱이 무대 그림으로 1024px PNG를 그리고, 크기별로 줄여 assets/AppIcon.icns로 묶는다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
swift build
.build/debug/RunTime --app-icon "$WORK/icon.png"
SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" > /dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
ls -la assets/AppIcon.icns
