#!/bin/bash
# RunTime 원클릭 설치: 서명 identity 준비 → 빌드 → 응용 프로그램 폴더로 복사 → 실행.
#
#   git clone https://github.com/youminki/RunTime.git && cd RunTime && ./install.sh
#
# 로컬에서 빌드하므로 Gatekeeper 격리(quarantine) 없이 바로 실행된다.
set -euo pipefail
cd "$(dirname "$0")"

echo "RunTime 설치를 시작합니다"

# 앱 안 업데이트와 직접 실행이 겹치면 같은 .build를 함께 고쳐 빌드가 깨진다. 한 번에 하나만 돈다
# TMPDIR은 앱이 띄운 셸과 터미널이 달라 늘 같은 자리에 둔다
mkdir -p "$HOME/Library/Caches/RunTime"
LOCK="$HOME/Library/Caches/RunTime/install.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 강제로 끝나 남은 잠금(30분 넘음)은 치운다
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "$LOCK" && mkdir "$LOCK"
  else
    echo "✗ 다른 설치가 진행 중입니다. 끝난 뒤 다시 실행하세요." >&2
    exit 1
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# 1) Swift 툴체인 확인
if ! command -v swift > /dev/null; then
  echo "✗ Swift가 없습니다. Xcode 또는 Command Line Tools를 설치하세요:" >&2
  echo "    xcode-select --install" >&2
  exit 1
fi

# 2) 고정 서명 identity (최초 1회 — macOS가 로그인 암호를 물으면 승인)
scripts/setup-signing.sh

# 3) 빌드
# 옛 저장소 주소(ClaudeTokenCat)는 GitHub 리디렉트에만 기대므로, 업데이트 확인과 pull이 RunTime 주소를 보게 한다
ORIGIN=$(git remote get-url origin 2>/dev/null || true)
RENAMED=$(printf '%s' "$ORIGIN" | sed -E 's#(github\.com[:/]youminki/)ClaudeTokenCat(\.git)?/?$#\1RunTime\2#')
[ "$RENAMED" = "$ORIGIN" ] || git remote set-url origin "$RENAMED"
[ ! -d Sources/TokenCat ] || find Sources/TokenCat -depth -type d -empty -delete
scripts/build-app.sh

# 4) 응용 프로그램 폴더로 설치 (/Applications 불가 시 ~/Applications)
TARGET="/Applications"
if [ ! -w "$TARGET" ]; then
  TARGET="$HOME/Applications"
  mkdir -p "$TARGET"
fi
# 옛 이름으로 설치한 앱은 실행 파일 이름이 TokenCat이다.
# 앱 안의 업데이트는 앱의 자식 프로세스로 돌아서, -a가 없으면 pkill·pgrep이 조상인 앱을 건너뛴다
pkill -a -x RunTime 2>/dev/null || true
pkill -a -x TokenCat 2>/dev/null || true
# 종료가 끝나기 전에 open하면 LaunchServices가 -600으로 실행을 거부한다
for _ in $(seq 1 50); do pgrep -a -x RunTime > /dev/null || pgrep -a -x TokenCat > /dev/null || break; sleep 0.1; done

# 옛 번들 ID로 설치한 앱(TokenCat.app, 이름만 바뀐 RunTime.app)은 지운다. 자동 시작 기록은 번들 ID에 묶여 있어서,
# 옛 앱에서 켜져 있었으면 새 앱이 처음 켜질 때 다시 등록하도록 남긴다
OLD_ID=dev.tokencat.TokenCat
OLDS=()
for OLD in /Applications/TokenCat.app "$HOME/Applications/TokenCat.app" /Applications/RunTime.app "$HOME/Applications/RunTime.app"; do
  [ -d "$OLD" ] || continue
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null || true)" = "$OLD_ID" ] \
    && OLDS+=("$OLD")
done
if [ ${#OLDS[@]} -gt 0 ]; then
  if BTM=$(sfltool dumpbtm 2>/dev/null) && [ -n "$BTM" ]; then
    # 경로 표기는 macOS 버전마다 달라서 번들 ID로 찾는다
    if printf '%s\n' "$BTM" | awk '
      /^ *#[0-9]+:$/ { if (id && on) found = 1; id = 0; on = 0 }
      /^ *Disposition:/ { on = ($0 ~ /\[enabled/) }
      /^ *(Bundle )?Identifier: (2\.)?dev\.tokencat\.TokenCat$/ { id = 1 }
      END { if (id && on) found = 1; exit !found }'; then
      defaults write dev.runtime.RunTime restoreLaunchAtLogin -bool true
    fi
  else
    echo "로그인 시 자동 시작 설정을 확인하지 못했습니다. 켜 두었다면 설정 > 일반에서 다시 켜세요." >&2
  fi
  for OLD in "${OLDS[@]}"; do
    rm -rf "$OLD" || echo "옛 앱($OLD)을 지우지 못했습니다. 직접 지워 주세요." >&2
  done
fi

rm -rf "$TARGET/RunTime.app"
cp -R dist/RunTime.app "$TARGET/"
scripts/place-menubar.sh

# 5) 실행
open "$TARGET/RunTime.app"

cat <<'GUIDE'

✅ 설치 완료 — 메뉴바에 러너가 나타납니다.

첫 실행 안내 (각 1회):
  • 키체인 프롬프트("security가 ... 접근하려고 합니다")가 뜨면
    반드시 [항상 허용]을 누르세요. [허용]만 누르면 다음에 또 묻습니다.
  • 알림 권한 요청은 한도 80%/95% 경고에 쓰입니다 — 허용 권장.

제거: 응용 프로그램 폴더에서 RunTime.app 삭제.
업데이트: git pull --ff-only && ./install.sh (설정 > 정보에서도 가능)
GUIDE
