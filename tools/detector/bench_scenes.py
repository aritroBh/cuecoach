#!/usr/bin/env python3
"""Write the held-out "virtual sim" detector benchmark (D32): short hand-held clips rendered by `sim3d`.

Each clip fixes a table, cloth, lamps and ball layout; its frames vary the hand-held camera, the noise, and
(optionally) moving balls, a cue stick and hands. Output (ignored by git): `data/bench/<name>/frames/*.jpg` and
`manifest.json` with per-frame camera (ARKit convention), table size, ground-truth balls and scene factors.

    uv run python bench_scenes.py --clips 60 --frames 6 --empty-clips 10

Seeds live in their own namespace (BENCH_NAMESPACE) and style ("bench"), disjoint from every training render.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

import sim3d

BENCH_NAMESPACE = 0xD32BE7C4
HERE = Path(__file__).parent


def clip_rng(seed: int, clip: int, frame: int | None = None) -> np.random.Generator:
    key = [BENCH_NAMESPACE, seed, clip] + ([] if frame is None else [frame])
    return np.random.default_rng(np.random.SeedSequence(key))


def render_clip(args: tuple) -> list[dict]:
    out_dir, seed, clip, frames, empty, style = args
    rng = clip_rng(seed, clip)
    scene = sim3d.make_scene(rng, style=style, empty=empty)
    base_cam, cam_info = sim3d.sample_camera(rng, scene)
    occluded = bool(rng.random() < 0.35)
    moving = bool(not empty and rng.random() < 0.25)
    if moving:
        movers = rng.choice(len(scene.balls), size=min(len(scene.balls), int(rng.integers(1, 4))), replace=False)
        for i in movers:
            a, v = rng.uniform(0, math.tau), rng.uniform(0.3, 2.5)
            scene.balls[int(i)].velocity = (math.cos(a) * v, math.sin(a) * v)
    shake = float(rng.choice([0.3, 1.0, 2.0]))
    occ = sim3d.make_occluders(rng, scene, cam_info) if occluded else None
    rows = []
    for f in range(frames):
        frng = clip_rng(seed, clip, f)
        cam = base_cam if f == 0 else sim3d.jitter_camera(frng, cam_info, shake)
        if moving and f > 0:
            for b in scene.balls:
                if b.velocity != (0.0, 0.0):
                    b.x = float(np.clip(b.x + b.velocity[0] / 30, sim3d.BALL_R * 1.1, scene.length - sim3d.BALL_R * 1.1))
                    b.y = float(np.clip(b.y + b.velocity[1] / 30, sim3d.BALL_R * 1.1, scene.width - sim3d.BALL_R * 1.1))
        image, truth, factors = sim3d.render(scene, cam, frng, occluders=occ)
        name = f"c{clip:03d}_f{f:02d}.jpg"
        (out_dir / "frames" / name).write_bytes(factors.pop("jpeg_bytes").tobytes())
        rows.append({
            "file": f"frames/{name}", "clip": clip, "frame": f, "timestamp": f / 30, "table": scene.table,
            "camera": cam.as_json(), "balls": truth,
            "factors": {**scene.tags, **{k: v for k, v in cam_info.items() if k != "target"}, **factors,
                        "occluders": occluded, "moving": moving, "empty": empty, "style": style},
        })
    return rows


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, default=HERE / "data" / "bench" / "v1")
    p.add_argument("--seed", type=int, default=32)
    p.add_argument("--clips", type=int, default=60)
    p.add_argument("--empty-clips", type=int, default=10)
    p.add_argument("--frames", type=int, default=6)
    p.add_argument("--style", default="bench", choices=["bench", "train"])
    p.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    a = p.parse_args()
    (a.out / "frames").mkdir(parents=True, exist_ok=True)
    jobs = [(a.out, a.seed, c, a.frames, c >= a.clips, a.style) for c in range(a.clips + a.empty_clips)]
    rows: list[dict] = []
    with ProcessPoolExecutor(a.workers) as pool:
        for r in pool.map(render_clip, jobs):
            rows.extend(r)
    manifest = {"version": 1, "seed": a.seed, "namespace": BENCH_NAMESPACE, "style": a.style,
                "ballRadius": sim3d.BALL_R, "frames": rows}
    (a.out / "manifest.json").write_text(json.dumps(manifest))
    print(f"wrote {len(rows)} frames from {len(jobs)} clips to {a.out}")


if __name__ == "__main__":
    main()
