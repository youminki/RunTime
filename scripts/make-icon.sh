#!/bin/zsh
# 앱 아이콘 만들기: 앱이 무대 그림으로 1024px PNG를 그리고, 크기별로 줄여 assets/AppIcon.icns로 묶는다.
# 아이콘 주인공은 Petdex에서 받은 짱구와 부리부리 대마왕이다. 받아 두지 않았으면 기본 펫 고양이로 그린다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
swift build
PETS="$HOME/Library/Application Support/RunTime/Petdex"
if [[ -d "$PETS/crayon-shin-chan" && -d "$PETS/futuduozaemon" ]]; then
  .build/debug/RunTime --app-icon "$WORK/icon.png" "$PETS/crayon-shin-chan" "$PETS/futuduozaemon"
else
  .build/debug/RunTime --app-icon "$WORK/icon.png"
fi
SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" > /dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
ls -la assets/AppIcon.icns
