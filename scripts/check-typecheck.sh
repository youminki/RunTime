#!/bin/zsh
# 타입 추론이 오래 걸리는 식을 찾는다. Xcode 16의 컴파일러에서 "unable to type-check this expression in
# reasonable time"으로 빌드를 멈춘 식은 새 컴파일러로도 수백 ms 걸렸다 (CI 실행기에서 270~600ms).
# CI 실행기는 같은 식도 실행마다 두세 배씩 흔들려서 한도를 300ms로 둔다.
# 사용: scripts/check-typecheck.sh [한도 ms, 기본 300]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-300}"
cd "$ROOT"
# 이미 빌드된 모듈은 다시 검사하지 않으므로 따로 둔 자리에서 처음부터 빌드한다
rm -rf .build/typecheck
LOG="$(swift build --build-path .build/typecheck \
    -Xswiftc -Xfrontend -Xswiftc "-warn-long-expression-type-checking=$LIMIT" 2>&1)" || { print -r -- "$LOG"; exit 1; }
SLOW="$(print -r -- "$LOG" | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E '^/.*warning: expression took' | sort -u || true)"
if [[ -n "$SLOW" ]]; then
    print -r -- "$SLOW"
    echo "✗ 타입 추론이 ${LIMIT}ms를 넘는 식이 있습니다. 클로저 체인을 반복문으로 풀거나 중간 값에 타입을 적으세요." >&2
    exit 1
fi
echo "✓ 모든 식이 ${LIMIT}ms 안에 타입 추론됩니다"
