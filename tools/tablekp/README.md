# Table keypoints

Python 3.12, seeded synthetic YOLO pose data, MPS training, held-out pixel error, and Core ML export.

```sh
cd tools/tablekp
uv sync
uv run python generate_dataset.py
uv run pytest
uv run python train.py --device mps
uv run python evaluate.py --weights runs/yolo26n-table-keypoints/weights/best.pt --split test
uv run python export_coreml.py --weights runs/yolo26n-table-keypoints/weights/best.pt
```

The label row is one table box followed by ten normalized `(x, y, visibility)` triples. Pocket keypoints 0–3 are corners clockwise from the visually topmost projected nose; 4–5 are side mouths from top to bottom in the image; 6–9 are nose corners in the same clockwise order. Labels identify corner versus side pockets only. The app should treat each group as unordered and resolve head/foot from table-plane geometry and D12 measurements.

The synthetic set varies 7/8/9 ft table geometry, 15–60 degree camera elevation, tripod/handheld framing, felt/rail finishes, balls, room clutter, lighting, blur, crops, and arm/cue occlusion. Exported test split is never used for training.

For later real-frame fine-tuning, place an annotated YOLO-pose dataset at `tools/footage/tablekeypoints/dataset.yaml`, with the same single class and `kpt_shape: [10, 3]`, then pass it as `--data` and the synthetic `best.pt` as `--model` to `train.py`. Footage stays gitignored and outside this package.
