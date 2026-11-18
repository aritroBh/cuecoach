#!/usr/bin/env python3
"""YOLO training data from the 3D renderer in its *train* style (never the bench style or seed namespace).

    uv run python sim3d_dataset.py --train 3000 --val 300 --out data/sim3d_train

Boxes are the projected sphere's bounding square; balls under 30 % visible or out of frame are left unlabelled.
"""

from __future__ import annotations

import argparse
import json
import os
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

import sim3d
from generate_dataset import CLASS_NAMES, validate_labels

TRAIN_NAMESPACE = 0x7A1E3D
SIZE = (960, 720)


def labels_for(truth: list[dict], w: int, h: int) -> list[tuple[int, float, float, float, float]]:
    out = []
    for t in truth:
        if t["image"] is None or t["visible"] < 0.3:
            continue
        u, v = t["image"]
        r = t["radius_px"] * 1.02
        x0, x1 = max(0.0, u - r), min(float(w), u + r)
        y0, y1 = max(0.0, v - r), min(float(h), v + r)
        if x1 - x0 < 3 or y1 - y0 < 3:
            continue
        out.append((int(t["number"]), (x0 + x1) / 2 / w, (y0 + y1) / 2 / h, (x1 - x0) / w, (y1 - y0) / h))
    return out


def render_one(job: tuple) -> None:
    out, split, index, seed = job
    rng = np.random.default_rng(np.random.SeedSequence([TRAIN_NAMESPACE, seed, split == "val", index]))
    scene = sim3d.make_scene(rng, style="train", empty=bool(rng.random() < 0.05))
    if not scene.balls or rng.random() < 0.5:
        pass
    for b in scene.balls:
        if rng.random() < 0.12:
            a, s = rng.uniform(0, 2 * np.pi), rng.uniform(0.3, 2.5)
            b.velocity = (float(np.cos(a) * s), float(np.sin(a) * s))
    cam, info = sim3d.sample_camera(rng, scene, *SIZE)
    occ = sim3d.make_occluders(rng, scene, info) if rng.random() < 0.35 else None
    _, truth, factors = sim3d.render(scene, cam, rng, occluders=occ)
    labels = labels_for(truth, *SIZE)
    validate_labels(labels, *SIZE)
    name = f"{index:05d}"
    (out / "images" / split / f"{name}.jpg").write_bytes(factors["jpeg_bytes"].tobytes())
    (out / "labels" / split / f"{name}.txt").write_text("".join("{} {:.6f} {:.6f} {:.6f} {:.6f}\n".format(*l) for l in labels))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, default=Path(__file__).parent / "data" / "sim3d_train")
    p.add_argument("--train", type=int, default=3000)
    p.add_argument("--val", type=int, default=300)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    a = p.parse_args()
    out = a.out.resolve()
    jobs = []
    for split, n in (("train", a.train), ("val", a.val)):
        (out / "images" / split).mkdir(parents=True, exist_ok=True)
        (out / "labels" / split).mkdir(parents=True, exist_ok=True)
        jobs += [(out, split, i, a.seed) for i in range(n)]
    with ProcessPoolExecutor(a.workers) as pool:
        list(pool.map(render_one, jobs, chunksize=8))
    (out / "dataset.yaml").write_text(json.dumps({"path": str(out), "train": "images/train", "val": "images/val",
                                                  "names": CLASS_NAMES}, indent=2) + "\n")
    print(f"wrote {len(jobs)} train-style 3D scenes to {out}")


if __name__ == "__main__":
    main()
