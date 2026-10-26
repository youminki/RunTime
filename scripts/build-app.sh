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
swift build -c release

APP=dist/RunTime.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/RunTime "$APP/Contents/MacOS/"
# SPM 리소스 번들 (스프라이트 Assets) — Bundle.module이 Contents/Resources에서 찾음
if [ -d .build/release/RunTime_RunTime.bundle ]; then
  cp -R .build/release/RunTime_RunTime.bundle "$APP/Contents/Resources/"
fi
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
codesign --force --deep -s "$CODESIGN_IDENTITY" "$APP"

echo "▸ dmg 생성"
hdiutil create -volname RunTime -srcfolder "$APP" -ov -format UDZO dist/RunTime.dmg > /dev/null

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ notarize 제출"
  xcrun notarytool submit dist/RunTime.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler staple dist/RunTime.dmg
fi

echo "✓ 완료: $APP, dist/RunTime.dmg"
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Authority" || true
