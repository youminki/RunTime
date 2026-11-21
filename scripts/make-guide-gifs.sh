#!/bin/zsh
# 사용법 영상 만들기: 예시 데이터로 앱 화면을 찍고 확대·커서·자막을 합성해 mp4(앱용)와 GIF(README용)를 만든다.
# 결과: Sources/RunTime/Assets/Guide/<장면>.mp4, <장면>.json(단계 시작 시각), assets/guide/<장면>.gif
# 내 업무 일지, hosts, 열린 포트, 설정이 영상에 남지 않게 예시 파일과 빈 홈 폴더를 가리켜 돌린다. ffmpeg가 있어야 한다.
# 사용법: scripts/make-guide-gifs.sh [장면,...]   (장면: workLog hosts ports windows clipboard usage runners redmine figma)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
swift build
BIN="$ROOT/.build/debug/RunTime"
ONLY="${1:-}"

export RUNTIME_NO_KEYCHAIN=1
export RUNTIME_WORKLOG="$WORK/worklog.json"
export RUNTIME_HOSTS="$WORK/hosts"
export RUNTIME_PORTS_DEMO=1
export RUNTIME_DESIGN_HISTORY="$WORK/none.json"
export CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$CFFIXED_USER_HOME"

DAY="$(date +%F)"
"$BIN" --worklog add "쇼핑몰 앱" "상품 목록 무한 스크롤 구현" 완료 --day "$DAY" >/dev/null
"$BIN" --worklog add "쇼핑몰 앱" "장바구니 수량 변경 API 연동" 60% --day "$DAY" >/dev/null
"$BIN" --worklog add "쇼핑몰 앱" "결제 화면 QA 수정사항 5건 반영" 완료 --day "$DAY" >/dev/null
"$BIN" --worklog add "관리자 웹" "주문 목록 필터 마크업" 완료 --day "$DAY" >/dev/null
"$BIN" --worklog add "관리자 웹" "회원 상세 화면 퍼블리싱" 40% --day "$DAY" >/dev/null
printf '127.0.0.1\tlocalhost\n\n## Local\n127.0.0.1 shop.local.test admin.local.test\n\n## Dev\n10.0.1.20 api.dev.example.com\n10.0.1.20 admin.dev.example.com\n\n## Stg\n#10.0.2.31 api.stg.example.com\n#10.0.2.31 admin.stg.example.com\n' > "$RUNTIME_HOSTS"

# 클립보드 띠는 별도 창이라 정지 화면을 찍어 두고 장면에서 보여 준다
export RUNTIME_CLIP_STILLS="$WORK/clip"
mkdir -p "$RUNTIME_CLIP_STILLS"
"$BIN" --clip-shots "$RUNTIME_CLIP_STILLS" >/dev/null

"$BIN" --guide-clips "$WORK/frames" ${ONLY:+"$ONLY"}

mkdir -p Sources/RunTime/Assets/Guide assets/guide
for dir in "$WORK"/frames/*/; do
    id="$(basename "$dir")"
    mp4="Sources/RunTime/Assets/Guide/$id.mp4"
    # 앱용: 2배 해상도 30fps H.264. 글자가 또렷하고 용량은 작다
    ffmpeg -v error -y -framerate 30 -i "$dir/%05d.png" -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p \
        -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -movflags +faststart "$mp4"
    cp "$dir/meta.json" "Sources/RunTime/Assets/Guide/$id.json"
    # README용 GIF: 12fps, 폭 720. 글자가 읽히게 하면서 용량을 줄인다
    ffmpeg -v error -y -i "$mp4" \
        -vf "fps=12,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
        "assets/guide/$id.gif"
    /bin/ls -la "$mp4" "assets/guide/$id.gif"
done
