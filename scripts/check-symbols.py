#!/usr/bin/env python3
"""앱이 쓰는 SF Symbol이 최소 지원 macOS에 있는지 본다.

없는 이름은 Image(systemName:)가 오류 없이 빈칸으로 그려서, 오래된 macOS에서만 아이콘이 사라진다.
이 Mac의 CoreGlyphs에 든 심볼별 출시 연도를 읽어 Info.plist의 LSMinimumSystemVersion과 견준다.
사용: python3 -I scripts/check-symbols.py
"""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AVAILABILITY = Path("/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
# systemName: "x", systemImage: "x", icon: "x" 처럼 심볼 이름을 받는 자리와 심볼만 돌려주는 return/case 줄
PATTERNS = [
    re.compile(r'(?:systemName|systemImage|systemSymbolName|icon|image)\s*:\s*"([a-z0-9][a-z0-9.]*)"'),
    re.compile(r'return\s+"([a-z0-9]+(?:\.[a-z0-9]+)+)"'),
    re.compile(r'\?\s*"([a-z0-9]+(?:\.[a-z0-9]+)+)"\s*:\s*"([a-z0-9]+(?:\.[a-z0-9]+)+)"'),
]


def version_tuple(text):
    return tuple(int(part) for part in text.split("."))


def main():
    if not AVAILABILITY.exists():
        print("심볼 정보 파일이 없어 건너뜁니다")
        return 0
    data = plistlib.loads(AVAILABILITY.read_bytes())
    symbols, releases = data["symbols"], data["year_to_release"]
    info = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
    minimum = version_tuple(info["LSMinimumSystemVersion"])

    problems = []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            names = {name for pattern in PATTERNS for match in pattern.finditer(line) for name in match.groups()}
            for name in names:
                year = symbols.get(name)
                if year is None:
                    continue  # 심볼이 아닌 문자열 (이 패턴은 넓게 잡는다)
                macos = releases.get(year, {}).get("macOS")
                if macos and version_tuple(macos) > minimum:
                    problems.append(f"{path.relative_to(ROOT)}:{number}: '{name}'는 macOS {macos}부터 있습니다")
    for problem in problems:
        print(problem)
    if problems:
        print(f"✗ macOS {info['LSMinimumSystemVersion']}에 없는 심볼 {len(problems)}개", file=sys.stderr)
        return 1
    print(f"✓ 모든 심볼이 macOS {info['LSMinimumSystemVersion']}에 있습니다")
    return 0


if __name__ == "__main__":
    sys.exit(main())
