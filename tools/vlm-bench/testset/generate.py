# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Render the CueCoach VLM benchmark test set.

Synthetic pool-table keyframes (top-down and 30-50 degree perspective from the head end) with
known ball layouts, plus ground-truth questions in testset.json.

Output: ../CueVLMBench/TestSet/{*.png, testset.json}. Deterministic (fixed seed).
Run: cd tools/vlm-bench/testset && uv run generate.py
"""
from __future__ import annotations

import json
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent.parent / "CueVLMBench" / "TestSet"

# Table geometry in inches (9 ft table). X across (0..W), Y along (0 = head rail .. L = foot rail).
W, L = 50.0, 100.0
BALL_R = 1.125
RAIL = 5.0
HEAD_STRING_Y = L / 4  # kitchen = 0 <= y < 25

POCKETS = {
    "headLeft": (0.0, 0.0),
    "headRight": (W, 0.0),
    "sideLeft": (0.0, L / 2),
    "sideRight": (W, L / 2),
    "footLeft": (0.0, L),
    "footRight": (W, L),
}

COLORS = {
    1: (240, 200, 20), 2: (20, 60, 200), 3: (210, 30, 30), 4: (100, 30, 150),
    5: (245, 120, 20), 6: (20, 130, 50), 7: (120, 25, 25), 8: (15, 15, 15),
}

CLOTH = (22, 110, 70)
RAILC = (90, 50, 25)
POCKETC = (8, 8, 8)


def font(size: int) -> ImageFont.ImageFont:
    for name in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


# ---------------------------------------------------------------- projection
class TopDown:
    """Head rail at the bottom of the image, foot rail at the top."""

    def __init__(self, px_per_in: float = 11.0):
        self.s = px_per_in
        self.size = (int((W + 2 * RAIL + 4) * self.s), int((L + 2 * RAIL + 4) * self.s))

    def project(self, x: float, y: float, z: float = 0.0):
        off = (RAIL + 2) * self.s
        return off + x * self.s, self.size[1] - (off + y * self.s), self.s


class Perspective:
    """Pinhole camera behind the head rail, pitched down `pitch_deg` toward table centre."""

    def __init__(self, pitch_deg: float, dist: float = 110.0, size=(1000, 1000), fov_deg: float = 60.0):
        self.size = size
        p = math.radians(pitch_deg)
        cx, cy = W / 2, L * 0.45
        self.cam = (cx, cy - dist * math.cos(p), dist * math.sin(p))
        fwd = (0.0, math.cos(p), -math.sin(p))
        right = (1.0, 0.0, 0.0)
        up = (0.0, math.sin(p), math.cos(p))
        self.axes = (right, up, fwd)
        self.f = (size[1] / 2) / math.tan(math.radians(fov_deg) / 2)

    def project(self, x: float, y: float, z: float = 0.0):
        d = (x - self.cam[0], y - self.cam[1], z - self.cam[2])
        right, up, fwd = self.axes
        xc = sum(a * b for a, b in zip(d, right))
        yc = sum(a * b for a, b in zip(d, up))
        zc = sum(a * b for a, b in zip(d, fwd))
        u = self.size[0] / 2 + self.f * xc / zc
        v = self.size[1] / 2 - self.f * yc / zc
        return u, v, self.f / zc  # pixels per inch at that depth


# ---------------------------------------------------------------- drawing
def draw_table(img: Image.Image, cam, balls: dict[int, tuple[float, float]], label: str | None = None):
    d = ImageDraw.Draw(img)

    def poly(pts):
        return [cam.project(x, y)[:2] for x, y in pts]

    r = RAIL
    d.polygon(poly([(-r, -r), (W + r, -r), (W + r, L + r), (-r, L + r)]), fill=RAILC)
    d.polygon(poly([(0, 0), (W, 0), (W, L), (0, L)]), fill=CLOTH)
    # head string + foot spot markers, like real cloth
    d.line(poly([(0, HEAD_STRING_Y), (W, HEAD_STRING_Y)]), fill=(60, 150, 100), width=2)
    for x, y in POCKETS.values():
        u, v, s = cam.project(x, y)
        pr = 2.4 * s
        d.ellipse([u - pr, v - pr * 0.75 if isinstance(cam, Perspective) else v - pr, u + pr, v + pr * 0.75 if isinstance(cam, Perspective) else v + pr], fill=POCKETC)
    # far balls first so near balls overlap them
    for n, (x, y) in sorted(balls.items(), key=lambda kv: -kv[1][1]):
        u, v, s = cam.project(x, y, BALL_R)
        br = BALL_R * s
        draw_ball(d, n, u, v, br)
    if label:
        d.rectangle([0, 0, img.size[0], 52], fill=(0, 0, 0))
        d.text((16, 8), label, fill=(255, 255, 255), font=font(36))


def draw_ball(d: ImageDraw.ImageDraw, n: int, u: float, v: float, r: float):
    box = [u - r, v - r, u + r, v + r]
    if n == 0:
        d.ellipse(box, fill=(250, 250, 245), outline=(180, 180, 170))
        return
    base = COLORS[(n - 1) % 8 + 1] if n != 8 else COLORS[8]
    if n <= 8:
        d.ellipse(box, fill=base)
    else:  # stripe: white ball with a coloured band
        d.ellipse(box, fill=base)
        d.chord(box, 215, 325, fill=(250, 250, 245))  # top white cap
        d.chord(box, 35, 145, fill=(250, 250, 245))  # bottom white cap
    # number disc
    dr = r * 0.48
    d.ellipse([u - dr, v - dr, u + dr, v + dr], fill=(250, 250, 245))
    f = font(max(8, int(r * 0.8)))
    t = str(n)
    tb = d.textbbox((0, 0), t, font=f)
    d.text((u - (tb[2] - tb[0]) / 2 - tb[0], v - (tb[3] - tb[1]) / 2 - tb[1]), t, fill=(0, 0, 0), font=f)


# ---------------------------------------------------------------- layouts
def random_layout(rng: random.Random, n_obj: int, cue_in_kitchen: bool):
    balls: dict[int, tuple[float, float]] = {}
    nums = rng.sample(range(1, 16), n_obj)

    def free(x, y):
        if any(math.hypot(x - a, y - b) < 2 * BALL_R + 0.6 for a, b in balls.values()):
            return False
        return all(math.hypot(x - px, y - py) > 5 for px, py in POCKETS.values())

    def place(n, ymin, ymax):
        for _ in range(2000):
            x = rng.uniform(BALL_R + 1, W - BALL_R - 1)
            y = rng.uniform(ymin, ymax)
            if free(x, y):
                balls[n] = (x, y)
                return
        raise RuntimeError("could not place ball")

    if cue_in_kitchen:
        place(0, 3, HEAD_STRING_Y - 3)
    else:
        place(0, HEAD_STRING_Y + 4, L - 6)
    for n in nums:
        place(n, HEAD_STRING_Y + 2, L - 3)  # object balls above head string keeps Q2 unambiguous
    return balls


def render(cam_kind: str, pitch: float, balls, label=None):
    cam = TopDown() if cam_kind == "top" else Perspective(pitch)
    img = Image.new("RGB", cam.size, (40, 40, 44))
    draw_table(img, cam, balls, label)
    return img


SHOT_LABELS = [
    # (description, acceptable keywords (lowercase stems), expected rating class)
    ("Break shot: the cue ball smashed into the full rack and two balls dropped.",
     ["break", "smash", "opening", "power", "cannon", "rack", "boom", "explosive"], "Book"),
    ("The player sank the 8-ball early while other balls of their group were still on the table, losing the rack.",
     ["early", "eight", "loss", "lost", "blunder", "disaster", "premature", "fatal", "game over", "oops"], "Blunder"),
    ("The cue ball followed the object ball straight into the corner pocket: a scratch, ball in hand to the opponent.",
     ["scratch", "foul", "mistake", "cue ball in", "in-off", "costly", "ouch"], "Mistake"),
    ("A razor-thin cut on the far 6-ball into the corner, then the cue ball stopped perfectly for the next shot.",
     ["cut", "thin", "great", "slice", "razor", "precision", "sharp", "clean", "nice", "perfect"], "Great"),
    ("Two-rail bank shot on the 9-ball into the side pocket to win the game, against long odds.",
     ["bank", "brilliant", "winner", "game winner", "clutch", "wow", "rail", "masterful", "genius", "amazing"], "Brilliant"),
    ("The player rolled the cue ball behind the 8-ball, leaving the opponent completely snookered with no shot.",
     ["safety", "snooker", "lock", "hide", "hidden", "shutout", "defense", "defence", "tactical", "smart"], "Great"),
]


def main():
    rng = random.Random(22)
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    items = []
    questions = []

    # 20 scenes: 10 top-down, 10 perspective (30..50 degrees). Cue in kitchen alternates.
    for i in range(20):
        kind = "top" if i < 10 else "persp"
        pitch = 0.0 if kind == "top" else [30, 35, 40, 45, 50][i % 5]
        n_obj = [3, 5, 7, 9, 11, 15, 4, 6, 8, 2][i % 10]
        in_kitchen = i % 2 == 0
        balls = random_layout(rng, n_obj, in_kitchen)
        name = f"scene{i:02d}_{kind}{int(pitch)}.png"
        render(kind, pitch, balls).save(OUT / name, optimize=True)
        objs = sorted(n for n in balls if n != 0)
        items.append({"image": name, "view": kind, "pitch": pitch, "balls": {str(k): v for k, v in balls.items()}})
        questions.append({"id": f"balls_{i:02d}", "kind": "ballsOnTable", "images": [name],
                          "truth": {"balls": objs, "cueBallPresent": True}})
        questions.append({"id": f"kitchen_{i:02d}", "kind": "cueInKitchen", "images": [name],
                          "truth": {"inKitchen": in_kitchen}})

        # 8 before/after pocket pairs (every other scene from 2 on, mixed views)
        if i % 5 in (1, 3):
            target = rng.choice(objs)
            pocket = list(POCKETS)[len([q for q in questions if q["kind"] == "pocketDrop"]) % 6]
            px, py = POCKETS[pocket]
            # ball sits in the jaws of the pocket, nudged onto the cloth so it stays visible
            nx = px + (1.6 if px == 0 else -1.6)
            ny = py + (1.6 if py == 0 else (-1.6 if py == L else 0.0))
            after = dict(balls)
            after[target] = (nx, ny)
            cx, cy = balls[0]
            after[0] = (min(max(cx + rng.uniform(-8, 8), 3), W - 3), min(cy + rng.uniform(8, 20), L - 8))
            b = render(kind, pitch, balls, "BEFORE")
            a = render(kind, pitch, after, "AFTER")
            pair = Image.new("RGB", (b.size[0] * 2 + 20, b.size[1]), (255, 255, 255))
            pair.paste(b, (0, 0))
            pair.paste(a, (b.size[0] + 20, 0))
            pname = f"pair{i:02d}_{kind}{int(pitch)}.png"
            pair.save(OUT / pname, optimize=True)
            questions.append({"id": f"pocket_{i:02d}", "kind": "pocketDrop", "images": [pname],
                              "ball": target, "truth": {"pocket": pocket}})

    for j, (desc, keys, cls) in enumerate(SHOT_LABELS):
        img = items[j * 3]["image"]
        questions.append({"id": f"label_{j:02d}", "kind": "shotLabel", "images": [img], "description": desc,
                          "truth": {"keywords": keys, "ratingClass": cls}})

    (OUT / "testset.json").write_text(json.dumps({"version": 1, "scenes": items, "questions": questions}, indent=1))
    print(f"{len(items)} scenes, {len(questions)} questions -> {OUT}")


if __name__ == "__main__":
    main()
