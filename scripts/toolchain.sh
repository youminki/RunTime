#!/bin/bash
# 빌드할 Swift 툴체인을 고른다. build-app.sh가 source 한다.
# Xcode와 Command Line Tools가 함께 있으면 Swift가 더 새것인 쪽을 쓰고, 6.0(Xcode 16)보다 오래됐으면 고치는 법을 알린다.
# 툴체인이 바뀌면 옛 컴파일러로 만든 모듈을 못 읽어 빌드가 깨지므로 .build를 비운다.

RUNTIME_MIN_SWIFT="6.0"

swift_version_of() {
  # Xcode 약관에 동의하지 않았거나 깨진 툴체인이면 빈 값
  DEVELOPER_DIR="$1" xcrun swift --version 2>/dev/null \
    | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)+).*/\1/p' | head -1
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

pick_toolchain() {
  local candidates=() best="" best_version="" dir version
  if [ -n "${DEVELOPER_DIR:-}" ]; then
    candidates=("$DEVELOPER_DIR")
  else
    candidates=("$(xcode-select -p 2>/dev/null || true)" /Applications/Xcode.app/Contents/Developer /Library/Developer/CommandLineTools)
  fi
  for dir in "${candidates[@]}"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    version=$(swift_version_of "$dir")
    [ -n "$version" ] || continue
    if [ -z "$best_version" ] || ! version_ge "$best_version" "$version"; then
      best="$dir"
      best_version="$version"
    fi
  done

  if [ -z "$best_version" ]; then
    echo "✗ 쓸 수 있는 Swift를 찾지 못했습니다." >&2
    if [ -d /Applications/Xcode.app ] && xcrun swift --version 2>&1 | grep -qi license; then
      echo "  Xcode 약관에 동의해야 합니다: sudo xcodebuild -license accept" >&2
    else
      echo "  Command Line Tools를 설치하세요: xcode-select --install" >&2
    fi
    return 1
  fi
  if ! version_ge "$best_version" "$RUNTIME_MIN_SWIFT"; then
    echo "✗ Swift 버전이 너무 오래됐습니다 (지금 ${best_version}, 필요 ${RUNTIME_MIN_SWIFT} 이상 · Xcode 16 이상)." >&2
    echo "  소프트웨어 업데이트에서 Command Line Tools를 올리거나, App Store에서 Xcode를 업데이트하세요." >&2
    echo "  Command Line Tools를 새로 받으려면: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install" >&2
    return 1
  fi
  export DEVELOPER_DIR="$best"
  echo "▸ Swift $best_version ($best)"

  local stamp=".build/.toolchain" current="$best_version $best"
  if [ -d .build ] && [ "$(cat "$stamp" 2>/dev/null)" != "$current" ]; then
    echo "▸ 툴체인이 바뀌어 이전 빌드 결과를 비웁니다"
    swift package clean >/dev/null 2>&1 || rm -rf .build/release .build/debug
  fi
  mkdir -p .build
  printf '%s' "$current" > "$stamp"
}
