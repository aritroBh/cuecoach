#!/usr/bin/env python3
"""Write the D32 fine-tune mix: every train-style 3D render plus a seeded sample of the original 2D renders
(so the model keeps what it learned), validated on the 3D val split. Never touches the bench scenes.

    uv run python finetune_mix.py --old ../../../detector/tools/detector/data/synthetic --old-count 1200
    uv run python train.py --data data/finetune_mix/dataset.yaml --model <synth30 best.pt> --epochs 10 --name yolo26n-sim3d-ft
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

from generate_dataset import CLASS_NAMES

HERE = Path(__file__).parent


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--sim3d", type=Path, default=HERE / "data" / "sim3d_train")
    p.add_argument("--old", type=Path, required=True, help="original 2D synthetic dataset root")
    p.add_argument("--old-count", type=int, default=1200)
    p.add_argument("--out", type=Path, default=HERE / "data" / "finetune_mix")
    p.add_argument("--seed", type=int, default=32)
    a = p.parse_args()
    new = sorted((a.sim3d / "images" / "train").resolve().glob("*.jpg"))
    old = sorted((a.old / "images" / "train").resolve().glob("*.jpg"))
    random.Random(a.seed).shuffle(old)
    train = [str(x) for x in new + old[: a.old_count]]
    val = [str(x) for x in sorted((a.sim3d / "images" / "val").resolve().glob("*.jpg"))]
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "train.txt").write_text("\n".join(train) + "\n")
    (a.out / "val.txt").write_text("\n".join(val) + "\n")
    (a.out / "dataset.yaml").write_text(json.dumps({"path": str(a.out.resolve()), "train": "train.txt", "val": "val.txt",
                                                    "names": CLASS_NAMES}, indent=2) + "\n")
    print(f"fine-tune mix: {len(new)} 3D + {min(a.old_count, len(old))} 2D train, {len(val)} val → {a.out}")


if __name__ == "__main__":
    main()
