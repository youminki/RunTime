#!/bin/zsh
# README 게임 GIF 만들기: 앱으로 달리기·비행 장면을 찍고 ffmpeg로 256색 GIF를 만든다. ffmpeg가 있어야 한다.
# README 예시 펫(짱구, 부리부리 대마왕)을 쓰려면 CFFIXED_USER_HOME으로 두 펫을 담은 폴더를 가리켜 실행한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT
cd "$ROOT"
swift build
make_gif() {
    ffmpeg -v error -y -framerate 20 -i "$1/%04d.png" \
        -vf "scale=516:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        "$2"
    ls -la "$2"
}
.build/debug/RunTime --game-frames "$FRAMES/run"
make_gif "$FRAMES/run" assets/runtime-game.gif
.build/debug/RunTime --flight-frames "$FRAMES/flight"
make_gif "$FRAMES/flight" assets/runtime-flight.gif
