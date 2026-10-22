#!/bin/zsh
# 코어 단위 테스트 (사용량 계산, 게임 규칙, 한글 검색, 업무 일지, 디자인 변경 기록).
# Command Line Tools만 있는 환경에선 실행 타깃과 같은 패키지에서 swift-testing 매크로를 찾지 못한다.
# 코어 소스와 테스트를 링크한 별도 패키지를 .build 안에 만들어 그쪽에서 돌린다.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/.build/core-package"
mkdir -p "$PKG/Sources" "$PKG/Tests"
for MODULE in UsageCore GameCore SearchCore WorkLogCore DesignSyncCore; do
    ln -sfn "$ROOT/Sources/$MODULE" "$PKG/Sources/$MODULE"
    ln -sfn "$ROOT/Tests/${MODULE}Tests" "$PKG/Tests/${MODULE}Tests"
done
cat > "$PKG/Package.swift" <<'MANIFEST'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageCoreTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UsageCore"),
        .target(name: "GameCore"),
        .target(name: "SearchCore"),
        .target(name: "WorkLogCore"),
        .target(name: "DesignSyncCore"),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
        .testTarget(name: "WorkLogCoreTests", dependencies: ["WorkLogCore"]),
        .testTarget(name: "DesignSyncCoreTests", dependencies: ["DesignSyncCore"]),
    ]
)
MANIFEST
cd "$PKG"
# 이 툴체인은 매크로 플러그인(TestingMacros) 로드나 빌드 단계가 가끔 실패한다.
# 그 경우에만 다시 빌드하고, 소스 위치가 찍힌 컴파일 오류는 바로 보여 준다.
for attempt in 1 2 3 4; do
    LOG="$(swift test "$@" 2>&1)" && { print -r -- "$LOG"; exit 0; }
    if [[ "$LOG" != *"plugin for module 'TestingMacros' not found"* ]] && print -r -- "$LOG" | grep -qE '\.swift:[0-9]+:[0-9]+: (\x1b\[[0-9;]*m)*error:'; then
        print -r -- "$LOG"
        exit 1
    fi
    if [[ "$LOG" == *"Test run with"* ]]; then   # 빌드는 됐고 테스트가 실패했다
        print -r -- "$LOG"
        exit 1
    fi
    echo "빌드 단계 실패, 다시 빌드 ($attempt)" >&2
done
print -r -- "$LOG"
exit 1
