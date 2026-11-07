"""RunTime 펫 만들기: FLUX.2 klein 4B(Apache 2.0)로 Petdex 규격(8x9) 펫 시트를 이 Mac에서 만든다.

기본 그림 한 장을 그린 뒤 그 그림을 참고로 동작 줄을 하나씩 그리고, hatch-pet 스크립트로 잘라 시트로 묶는다.
모델은 한 번만 읽는다. 진행은 한 줄짜리 JSON으로 표준 출력에 적는다 (앱이 읽는다).
"""
import argparse
import json
import os
import shutil
import subprocess
import statistics
import sys
import time
from pathlib import Path

from PIL import Image, ImageOps

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import compose_atlas  # noqa: E402
import extract_strip_frames as ex  # noqa: E402

MODEL = "Runpod/FLUX.2-klein-4B-mflux-4bit"
BASE_MODEL = "flux2-klein-4b"
KEY = (255, 0, 255)

# 줄 이름, 칸 수, 동작. running-left는 running-right를 뒤집고, running(일하는 중)은 RunTime이
# 달리기 줄이 빌 때만 써서 따로 그리지 않고 running-right 앞 여섯 칸을 쓴다
# 걷기는 8칸을 한 번에 그리면 앞·옆·뒷모습이 섞여 몸을 앞뒤로 돌리는 것처럼 보이고, 그냥 4칸을 시키면 다리가 거의 같다.
# 옆모습 기본 그림을 따로 그려 참고로 주고, 칸마다 다리 자세를 정해 4칸을 그린 뒤 되풀이한다
# 정면 캐릭터를 완전한 옆모습으로 돌리면 귀·날개 같은 부위를 지어내기 쉬워(훈이 귀가 하나 더 붙었다) 3/4 각도로 그린다
VIEW = "three-quarter view turned to the right, body facing right, face still visible"
WALK = (f"{VIEW} in every frame. A clear walking cycle in exactly 4 frames, left to right: "
        "frame 1 a big step with the front leg stretched far forward and the back leg far behind, arms swinging opposite; "
        "frame 2 legs passing together under the body, body slightly raised; "
        "frame 3 a big step with the other leg stretched far forward and the first leg far behind, arms swinging opposite; "
        "frame 4 legs passing together again")
ROWS = [
    ("idle", 6, "standing still and calm, gentle breathing, one frame blinking"),
    ("running-right", 4, WALK),
    ("waving", 4, "waving hello with one hand, the hand raised high in the middle frames"),
    ("jumping", 5, "a jump: crouching, taking off, highest point with arms up, falling, landing"),
    ("failed", 8, "sad and deflated while facing the viewer: head drooping, shoulders slumping, then sitting down sadly"),
    ("waiting", 6, "looking up expectantly with one hand raised, as if asking a question"),
    ("review", 6, "thinking with a hand on the chin, then looking closely through a magnifying glass"),
]


def emit(**event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def load_model():
    import mlx.core as mx
    # 16GB Mac에서 다른 앱과 함께 돌아도 스왑으로 느려지지 않게 MLX가 쥐고 있는 캐시를 줄인다
    try:
        mx.set_cache_limit(512 * 1024 * 1024)
    except AttributeError:
        mx.metal.set_cache_limit(512 * 1024 * 1024)
    from mflux.models.common.config.model_config import AVAILABLE_MODELS
    from mflux.models.common.resolution.config_resolution import ConfigResolution
    from mflux.models.flux2.variants import Flux2KleinEdit

    family = tuple(key for key in AVAILABLE_MODELS if key.startswith("flux2-") and key != BASE_MODEL)
    config = ConfigResolution.resolve_restricted(MODEL, BASE_MODEL, model_path=MODEL, extra_keys=family,
                                                 base_model=BASE_MODEL)
    return Flux2KleinEdit(model_config=config, model_path=MODEL)


def draw(model, prompt, path, width, height, seed, references):
    image = model.generate_image(seed=seed, prompt=prompt, width=width, height=height, guidance=1.0,
                                 image_paths=references, num_inference_steps=4,
                                 scheduler="flow_match_euler_discrete")
    image.save(path=str(path))
    return path


def key_out(path):
    """테두리에서 배경색을 재서 지우고, 외곽에 남은 분홍 테를 한 번 더 걷어 낸다."""
    image = Image.open(path).convert("RGB")
    w, h = image.size
    border = [image.getpixel((x, y)) for x in range(0, w, 7) for y in (0, 1, h - 2, h - 1)]
    key = tuple(int(statistics.median(c[i] for c in border)) for i in range(3))
    rgba = ex.remove_chroma_background(image, key, 95)
    pixels = rgba.load()
    for _ in range(2):
        clear = []
        for y in range(h):
            for x in range(w):
                r, g, b, a = pixels[x, y]
                if a == 0 or not (r > 140 and b > 110 and g < min(r, b) - 50):
                    continue
                near = any(0 <= x + dx < w and 0 <= y + dy < h and pixels[x + dx, y + dy][3] == 0
                           for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                if near:
                    clear.append((x, y))
        for x, y in clear:
            pixels[x, y] = (0, 0, 0, 0)
    return rgba


def stable_cells(strip, groups):
    """줄 안의 모든 칸을 같은 배율과 같은 바닥선으로 자른다. 칸마다 따로 맞추면 머리 크기가 출렁여 얼굴이 겹쳐 보인다."""
    padding = 4
    boxes = [ex.component_bounds(g) for g in groups]
    top = max(0, min(b[1] for b in boxes) - padding)
    bottom = min(strip.height, max(b[3] for b in boxes) + padding)
    width = max(b[2] - b[0] for b in boxes) + padding * 2
    cells = []
    for group, box in zip(groups, boxes):
        figure = ex.component_group_image(strip, group, padding=padding)
        view = Image.new("RGBA", (width, max(1, bottom - top)), (0, 0, 0, 0))
        view.alpha_composite(figure, ((width - figure.width) // 2, max(0, box[1] - padding) - top))
        cells.append(ex.fit_viewport_to_cell(view))
    return cells


def pick_side(base, sides, work):
    """기본 모습과 같은 캐릭터이고 귀·팔다리가 더 붙지 않은 옆모습을 Claude가 그림을 보고 고른다."""
    claude = os.environ.get("RUNTIME_CLAUDE")
    if not claude or not shutil.which(claude) and not Path(claude).exists():
        return sides[0]
    folder = work / "pick"
    folder.mkdir(exist_ok=True)
    names = ["base.png"] + [f"{i + 1}.png" for i in range(len(sides))]
    for name, path in zip(names, [base] + sides):
        shutil.copy(path, folder / name)
    system = ("너는 펫 그림 검수 도구다. base.png와 후보 1.png, 2.png를 Read 도구로 읽는다. base와 같은 캐릭터이면서 "
              "귀·날개·팔다리·눈이 더 붙거나 빠지지 않고 오른쪽을 향한 후보 번호 하나만 출력한다. 둘 다 같으면 1.")
    try:
        result = subprocess.run([claude, "-p", "--model", "sonnet", "--tools", "Read", "--allowedTools", "Read",
                                 "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
                                 "--output-format", "text", "--system-prompt", system],
                                input="후보를 골라 줘", capture_output=True, text=True, cwd=folder, timeout=90)
        digits = [c for c in result.stdout if c.isdigit()]
        choice = int(digits[-1]) if digits else 1
    except (OSError, subprocess.SubprocessError):
        choice = 1
    return sides[choice - 1] if 1 <= choice <= len(sides) else sides[0]


def figures(strip):
    components = ex.connected_components(strip)
    if not components:
        return []
    largest = max(c["area"] for c in components)
    return [c for c in components if c["area"] >= max(120, largest * 0.2)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--description", required=True)
    parser.add_argument("--reference", action="append", default=[], help="참고 그림. 세 장까지")
    parser.add_argument("--name", default="pet")
    parser.add_argument("--edit", help="고칠 점 (영어). 있으면 참고 그림(전에 그린 기본 모습)을 이만큼만 바꾼다")
    parser.add_argument("--out", required=True)
    parser.add_argument("--prepare-only", action="store_true", help="모델만 받아 두고 끝낸다")
    args = parser.parse_args()

    out = Path(args.out)
    work = out / "work"
    frames = out / "frames"
    for folder in (work, frames):
        folder.mkdir(parents=True, exist_ok=True)

    emit(step="load")
    model = load_model()
    if args.prepare_only:
        emit(step="ready")
        return
    started = time.time()
    total = 2 + len(ROWS)

    # 1. 기본 그림. 참고 그림이 있으면 그 캐릭터를 그대로 옮긴다
    emit(step="base", done=0, total=total)
    style = ("cute chibi pixel art game sprite, full body, clean dark outline, bold flat colors with simple shading, "
             "crisp pixels")
    if args.edit and args.reference:
        prompt = (f"Edit the character in the reference image: {args.edit}. Change only that and keep the same character, "
                  f"face, colors, outfit and {style} exactly. Standing, front view, centered, plain solid white background, no text.")
    elif args.reference:
        prompt = (f"Redraw the character from the reference image as a {style}: keep the same face, hair, outfit, "
                  f"colors and distinctive features. {args.description}. Standing, front view, centered, "
                  "plain solid white background, no text.")
    else:
        prompt = (f"On this blank white canvas, draw a {style} of {args.description}. Standing, front view, centered, "
                  "plain solid white background, no text.")
    # 편집 모델은 그림이 한 장은 있어야 해서, 참고 그림이 없으면 빈 흰 바탕에 그리게 한다
    blank = work / "blank.png"
    Image.new("RGB", (512, 512), "white").save(blank)
    references = args.reference[:3] or [str(blank)]
    # 시트 한 칸이 192x208이라 512면 충분하다. 크게 그리면 메모리와 시간만 는다
    base = draw(model, prompt, work / "base.png", 512, 512, 7, references)
    emit(step="preview", path=str(base))
    # 기본 모습은 나중에 '고치기'의 출발점으로 쓰려고 펫 폴더에 남긴다
    Image.open(base).save(out / "base.png")

    # 옆모습 기본 그림. 걷기 줄이 이 그림을 따라 모든 칸을 같은 방향으로 그린다.
    # 두 장을 그려 Claude가 부위가 더 붙지 않은 쪽을 고른다 (Claude를 못 쓰면 첫 장)
    emit(step="side", done=1, total=total)
    sides = [draw(model, f"Redraw the same character from the reference image in {VIEW}, full body, standing, identical face, "
                  "hair, outfit, colors and pixel art style, correct anatomy with no extra ears, limbs or body parts. "
                  "Plain solid white background, no text.", work / f"side-{seed}.png", 512, 512, seed, [str(base)])
             for seed in (7, 8)]
    side = pick_side(base, sides, work)
    emit(step="preview", path=str(side))

    identity = (f"the same character as in the reference image ({args.description}), identical face, hair, outfit, "
                "colors and pixel art style")
    report = {}
    for index, (state, count, action) in enumerate(ROWS, start=2):
        emit(step="row", state=state, done=index, total=total)
        if state == "running-right":
            prompt = (f"One horizontal animation sprite strip of {identity}, {action}. Exactly {count} full-body figures, "
                      "evenly spaced, same size, same baseline, no overlap. Flat pure magenta #FF00FF background, no text.")
            references = [str(side), str(base)]
        else:
            references = [str(base)]
            prompt = (f"One horizontal animation sprite strip of {identity}. Show exactly {count} separate frames of "
                      f"{action}. Exactly {count} complete full-body figures, evenly spaced left to right, same size, "
                      "same baseline, no overlap. Flat pure magenta #FF00FF background, no text, no shadows, no scenery.")
        # 한 칸에 176px쯤. 줄 폭은 칸 수에 맞춰 줄인다 (16의 배수)
        width = (count * 176 + 15) // 16 * 16
        best = None
        # 두 칸 넘게 모자랄 때만 한 번 더 그린다. 하나쯤 모자란 것은 앞 프레임을 되풀이해 메운다
        for seed in (5, 6):
            strip = key_out(draw(model, prompt, work / f"{state}-{seed}.png", width, 240, seed, references))
            found = len(figures(strip))
            if best is None or abs(found - count) < abs(best[1] - count):
                best = (strip, found)
            if found >= count - 1:
                break
        strip, found = best
        # 캐릭터마다 한 칸. 많이 그려졌으면 남는 것을 고르게 버린다 (옆 칸에 합치면 두 명이 한 칸에 든다)
        groups = ex.component_frame_groups(strip, max(1, found)) or []
        if len(groups) > count:
            step = len(groups) / count
            groups = [groups[int(i * step)] for i in range(count)]
        cells = stable_cells(strip, groups) if groups else ex.extract_slot_frames(strip, count)
        if state == "running-right":
            cells = [cells[i % len(cells)] for i in range(8)]
            count = 8
        preview = work / f"{state}-preview.png"
        strip.save(preview)
        emit(step="preview", path=str(preview), state=state)
        # 그래도 모자란 칸은 앞 프레임을 되풀이해 고리를 잇는다
        for i in range(count):
            cell = cells[i % len(cells)]
            cell.save(frames / f"{state}_{i:02d}.png")
            if state == "running-right":
                ImageOps.mirror(cell).save(frames / f"running-left_{i:02d}.png")
                if i < 6:
                    cell.save(frames / f"running_{i:02d}.png")
        report[state] = {"want": count, "found": found}

    emit(step="pack", done=total, total=total)
    atlas = compose_atlas.compose_from_frames(frames)
    atlas.save(out / "spritesheet.png")
    (out / "pet.json").write_text(json.dumps({"id": out.name, "displayName": args.name,
                                              "description": args.description,
                                              "spritesheetPath": "spritesheet.png"}, ensure_ascii=False))
    emit(step="done", seconds=round(time.time() - started), rows=report)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # 앱이 까닭을 보여 줄 수 있게 한 줄로 남긴다
        emit(step="failed", reason=f"{type(error).__name__}: {error}"[:300])
        sys.exit(1)
