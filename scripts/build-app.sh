#!/bin/bash
# RunTime.app 번들 + dmg 생성 (§6 M3).
#
# 사용법:
#   scripts/build-app.sh                          # 고정 identity 서명 (기본 "TokenCat Dev")
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#   NOTARY_PROFILE=<notarytool keychain profile> CODESIGN_IDENTITY=... scripts/build-app.sh
#
# ⚠ ad-hoc 서명(-s -) 금지: 빌드마다 서명이 바뀌어 키체인 ACL·TCC 승인이 리셋됨.
#   identity가 없으면 scripts/setup-signing.sh 를 먼저 1회 실행.
# notarize까지 하려면 사전에 1회:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-pw>
set -euo pipefail
cd "$(dirname "$0")/.."

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-TokenCat Dev}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CODESIGN_IDENTITY"; then
  echo "✗ 코드서명 identity \"$CODESIGN_IDENTITY\" 없음 — 먼저 실행: scripts/setup-signing.sh" >&2
  exit 1
fi

# Xcode와 Command Line Tools 가운데 Swift가 새것인 쪽을 고르고, 너무 오래됐으면 여기서 멈춘다
source scripts/toolchain.sh
pick_toolchain

echo "▸ release 빌드"
# 기본 빌드 시스템의 release는 모듈 전체 최적화라 파일 하나만 바뀌어도 앱 모듈을 통째로 다시 컴파일해 업데이트마다 2분 넘게 걸린다.
# 예전 빌드 시스템에서 이를 끄면 바뀐 파일만 다시 컴파일해 20초 안팎으로 끝난다. 이 방식이 없는 Swift면 기본 빌드로 한다
if ! swift build -c release --build-system native -Xswiftc -no-whole-module-optimization; then
  echo "▸ release 빌드 (기본 빌드 시스템으로 다시)"
  swift build -c release
fi

APP=dist/RunTime.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/RunTime "$APP/Contents/MacOS/"
# SPM 리소스 번들 (스프라이트 Assets) — Bundle.module이 Contents/Resources에서 찾음
# 창 배치(WindowKit) 메뉴 아이콘 번들도 같은 자리에 둔다
for BUNDLE in RunTime_RunTime RunTime_WindowKit; do
  if [ -d ".build/release/$BUNDLE.bundle" ]; then
    cp -R ".build/release/$BUNDLE.bundle" "$APP/Contents/Resources/"
  fi
done
# 클립보드 기록(ClipKit) 문구는 Pesty처럼 앱 번들의 번역표에서 찾는다 (String(localized:)와 SwiftUI Text가 Bundle.main을 본다)
cp -R Sources/ClipKit/RunTime/ko.lproj "$APP/Contents/Resources/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
# 설정 화면에서 지금 설치된 빌드가 어느 커밋인지 확인할 수 있게 남긴다 (+ = 커밋 안 된 변경 포함)
# 앱 안의 업데이터는 이 클론 위치·저장소·기본 브랜치로 새 커밋을 확인하고, 이 클론에서 다시 빌드한다
if COMMIT=$(git rev-parse --short HEAD 2>/dev/null); then
  PLIST="$APP/Contents/Info.plist"
  DIRTY=false
  # 업데이터와 같은 기준: 추적하는 파일을 고쳤을 때만 (작업 메모 같은 untracked 파일은 세지 않는다)
  [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] || { COMMIT="$COMMIT+"; DIRTY=true; }
  # 따옴표·백슬래시가 든 경로나 제목도 그대로 들어가게 plutil로 넣는다
  put() { plutil -insert "$1" -string "$2" "$PLIST"; }
  # 빌드 번호는 커밋 수로 매긴다. 버전은 VERSION의 주.부 번호에, 그 파일을 마지막으로 고친 뒤 쌓인 커밋 수를 붙인다.
  # 커밋마다 버전이 저절로 오르고, 큰 변경 때만 VERSION을 고친다 (그러면 끝자리가 0부터 다시 센다)
  plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$PLIST"
  if [ -f VERSION ]; then
    BASE=$(tr -d '[:space:]' < VERSION)
    SINCE=$(git log -1 --format=%H -- VERSION 2>/dev/null || true)
    PATCH=$( [ -n "$SINCE" ] && git rev-list --count "$SINCE..HEAD" 2>/dev/null || echo 0)
    plutil -replace CFBundleShortVersionString -string "$BASE.$PATCH" "$PLIST"
  fi
  put RunTimeCommit "$COMMIT"
  put RunTimeCommitSHA "$(git rev-parse HEAD)"
  put RunTimeCommitSubject "$(git log -1 --format=%s)"
  put RunTimeSourcePath "$PWD"
  plutil -insert RunTimeDirty -bool "$DIRTY" "$PLIST"
  # https://(user@)github.com/o/r(.git)(/), git@github.com:o/r.git, ssh://git@github.com/o/r 에서 o/r만 뽑는다.
  # origin이나 origin/HEAD가 없는 클론도 설치는 되어야 해서 실패를 무시한다
  REPO=$( (git remote get-url origin 2>/dev/null || true) \
    | sed -E 's#^(https://([^@/]+@)?|ssh://git@|git@)github\.com[:/]##; s#/$##; s#\.git$##' \
    | grep -E '^[^/ ]+/[^/ ]+$' || true)
  BRANCH=$( (git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true) | sed 's#^origin/##')
  [ -n "$REPO" ] && put RunTimeRepo "$REPO"
  put RunTimeBranch "${BRANCH:-main}"
fi
cp assets/AppIcon.icns "$APP/Contents/Resources/"

echo "▸ 서명: $CODESIGN_IDENTITY"
# iCloud 동기화 폴더나 Finder를 거친 파일의 확장 속성이 남으면 codesign이 "detritus not allowed"로 멈춘다
xattr -cr "$APP" 2>/dev/null || true
# codesign 오류는 "경로: 까닭" 꼴이라 업데이터와 문제 보고가 찾는 실패 표시 줄로 다시 남긴다
if ! SIGN_OUT=$(codesign --force --deep -s "$CODESIGN_IDENTITY" "$APP" 2>&1); then
  echo "$SIGN_OUT"
  # 마지막 줄이 "In subcomponent: 경로"면 까닭이 아니라서 건너뛰고, 앞의 앱 경로는 떼어 까닭만 남긴다
  REASON=$(printf '%s\n' "$SIGN_OUT" | { grep -v '^In subcomponent' || true; } | tail -1)
  echo "✗ 서명 실패: ${REASON#*.app: }" >&2
  case "$SIGN_OUT" in
    *errSecInternalComponent*|*"User interaction is not allowed"*|*"user canceled"*)
      echo "✗ 키체인이 잠겼거나 codesign의 키 사용을 허용하지 않았습니다. 업데이트를 직접 다시 누르고 키체인 창에서 [항상 허용]을 누르세요. 한 번 누르면 다음부터 묻지 않습니다." >&2 ;;
    *ambiguous*)
      echo "✗ 키체인에 \"$CODESIGN_IDENTITY\" 인증서가 여러 개입니다. 키체인 접근에서 하나만 남기고 다시 업데이트하세요." >&2 ;;
  esac
  exit 1
fi
echo "$SIGN_OUT"

# install.sh(자동 업데이트 포함)는 앱만 쓰고 dmg는 나눠 줄 때만 쓴다. 업데이트마다 만들 까닭이 없다
if [ -n "${RUNTIME_APP_ONLY:-}" ] && [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "✓ 완료: $APP"
else
  echo "▸ dmg 생성"
  hdiutil create -volname RunTime -srcfolder "$APP" -ov -format UDZO dist/RunTime.dmg > /dev/null

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▸ notarize 제출"
    xcrun notarytool submit dist/RunTime.dmg --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler staple dist/RunTime.dmg
  fi

  echo "✓ 완료: $APP, dist/RunTime.dmg"
fi
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Authority" || true
