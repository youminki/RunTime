#!/bin/bash
# 메뉴바에서 RunTime 자리를 다른 앱 아이콘들의 오른쪽 끝(시계·제어 센터 바로 왼쪽)으로 잡는다.
#
# macOS 27은 상태 항목 자리를 MenuBar.plist의 TrailingItemPreferredPositions에
# "status:<번들ID>::<autosaveName>" → 오른쪽 끝에서 잰 pt로 둔다. 처음 생긴 항목은 왼쪽 끝에 놓여
# 메뉴가 긴 앱 앞에서 « 안으로 먼저 접힌다. 사용자가 끌어 옮긴 자리는 지키려고 처음 한 번만 옮긴다.
set -u
DOMAIN="$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar"
KEY="status:dev.runtime.RunTime::RunTime"
# 이 자리 값의 뜻은 macOS 27에서 확인했다. 다른 버전에서는 건드리지 않는다
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 27 ] 2>/dev/null || exit 0
[ -f "$DOMAIN.plist" ] || exit 0
[ "$(defaults read dev.runtime.RunTime menuBarPlaced 2>/dev/null)" = "1" ] && exit 0

# 다른 앱 항목 가운데 가장 오른쪽 값보다 조금 작게 (값이 작을수록 오른쪽)
RIGHTMOST=$(defaults read "$DOMAIN" TrailingItemPreferredPositions 2>/dev/null \
  | awk -F' = ' -v key="\"$KEY\"" '
      $1 ~ /"status:/ && $1 !~ key {
        gsub(/[ ";]/, "", $2); v = $2 + 0
        if (v > 0 && (min == "" || v < min)) min = v
      }
      END { if (min != "") print min }')
TARGET=$(awk -v m="${RIGHTMOST:-168}" 'BEGIN { t = m - 8; if (t < 1) t = 1; print t }')

defaults write "$DOMAIN" TrailingItemPreferredPositions -dict-add "$KEY" -float "$TARGET" 2>/dev/null || exit 0
defaults write dev.runtime.RunTime menuBarPlaced -bool true
# 메뉴바가 새 자리를 읽도록 다시 띄운다 (macOS가 바로 되살린다)
killall MenuBarAgent 2>/dev/null || true
echo "메뉴바에서 RunTime 자리를 오른쪽 끝으로 잡았습니다. ⌘를 누른 채 끌면 옮길 수 있습니다."
