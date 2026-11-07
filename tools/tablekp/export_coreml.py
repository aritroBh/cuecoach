#!/usr/bin/env python3
"""Export a trained pose checkpoint to a compact FP16 Core ML package."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import coremltools as ct
from PIL import Image
from ultralytics import YOLO

from generate_dataset import KEYPOINT_NAMES, render_scene


ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / "CueCoach" / "Resources" / "Models" / "TableKeypoints.mlpackage"
METADATA = DESTINATION.with_suffix(".json")
MAX_BYTES = 15_000_000


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=DESTINATION)
    parser.add_argument("--max-mb", type=float, default=15)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    if not args.weights.is_file():
        parser.error(f"checkpoint does not exist: {args.weights}")
    output = args.out.resolve()
    metadata_path = output.with_suffix(".json")
    if output.suffix != ".mlpackage":
        parser.error("--out must end in .mlpackage")
    if output.exists() and not args.overwrite:
        parser.error(f"{output} exists; pass --overwrite to replace it")

    model = YOLO(str(args.weights))
    if model.task != "pose":
        parser.error(f"expected a pose checkpoint, found {model.task}")
    exported = Path(model.export(format="coreml", imgsz=640, quantize=16, nms=False,
                                 dynamic=False, device="cpu"))
    size = sum(path.stat().st_size for path in exported.rglob("*") if path.is_file())
    if size > args.max_mb * 1_000_000:
        raise RuntimeError(f"FP16 package is {size / 1_000_000:.2f} MB; limit is {args.max_mb:g} MB")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(exported, output)

    mlmodel = ct.models.MLModel(str(output), compute_units=ct.ComputeUnit.CPU_ONLY)
    spec = mlmodel.get_spec()
    inputs = [item for item in spec.description.input if item.type.WhichOneof("Type") == "imageType"]
    if not inputs or (inputs[0].type.imageType.width, inputs[0].type.imageType.height) != (640, 640):
        raise RuntimeError("Core ML package must accept a 640x640 image")
    prediction = mlmodel.predict({inputs[0].name: Image.fromarray(render_scene(20261106).image, mode="RGB")})
    if not prediction or not any(getattr(value, "size", 0) for value in prediction.values()):
        raise RuntimeError("Core ML prediction returned no tensor outputs")
    output_info = {name: list(value.shape) for name, value in prediction.items() if hasattr(value, "shape")}
    metadata = {
        "model": "Ultralytics YOLO26n-pose",
        "task": "single pool-table detection and keypoints",
        "input": {"width": 640, "height": 640, "color": "RGB"},
        "precision": "FP16",
        "keypoints": [{"index": i, "name": name} for i, name in enumerate(KEYPOINT_NAMES)],
        "keypoint_order": "0-3 corner mouths clockwise from the visually topmost projected nose corner; 4-5 side mouths top-to-bottom in the image; 6-9 nose corners in the same clockwise order. Treat each group as unordered and resolve camera/table orientation from geometry.",
        "corner_mouth_inches": 4.5,
        "side_mouth_inches": 5.0,
        "table_sizes_inches": [[80, 40], [92, 46], [100, 50]],
        "symmetry": "The model does not assign head/foot. Corner and side pocket groups are geometric; the app resolves head/foot and scale using its table-plane measurement.",
        "visibility": "Training labels use 0=outside frame, 1=occluded, 2=visible. Inference returns keypoint confidence values.",
        "outputs": output_info,
        "size_bytes": sum(path.stat().st_size for path in output.rglob("*") if path.is_file()),
    }
    metadata_path.write_text(json.dumps(metadata, separators=(",", ":")) + "\n")
    print(f"Exported {output} ({metadata['size_bytes'] / 1_000_000:.2f} MB, FP16)")
    print(f"Metadata: {metadata_path}")


if __name__ == "__main__":
    main()
