# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "coremltools==9.0",
#   "torch==2.15.0",
#   "onnx==1.23.2",
#   "onnx2torch==1.5.15",
#   "onnxruntime==1.31.1",
#   "numpy==2.3.5",
#   "pillow==13.0.0",
# ]
# ///
"""Convert the AuraFace-v1 recognition graph (glintr100.onnx, Apache-2.0) to a Core ML ML Program (FP16).

Input: one 112x112 RGB image, already 5-point aligned to the ArcFace template by the app (Vision landmarks +
similarity warp). The (x - 127.5) / 127.5 normalisation is baked into the image input, so the app hands Core ML a
plain 112x112 BGRA/RGB pixel buffer. Output: "embedding", 512 floats (not normalised; the app L2-normalises).

Checks the conversion against ONNX Runtime on random face-sized images: mean cosine must be >= 0.999.
Never touches the detector/landmark/attribute ONNX files from the same repo (face-embedding.md F1/F3).
"""
from __future__ import annotations

import argparse
import sys

import numpy as np


def first_ops(model) -> list[str]:
    return [n.op_type for n in model.graph.node[:4]]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--source", default="")
    ap.add_argument("--checks", type=int, default=8)
    a = ap.parse_args()

    import coremltools as ct
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert
    from PIL import Image

    m = onnx.load(a.onnx)
    inp = m.graph.input[0]
    dims = [d.dim_value for d in inp.type.tensor_type.shape.dim]
    print(f"onnx input {inp.name} {dims}, first ops {first_ops(m)}")
    # InsightFace convention: graphs that start with Sub/Mul normalise internally (mean 0, std 1).
    internal = first_ops(m)[:2] == ["Sub", "Mul"]
    mean, std = (0.0, 1.0) if internal else (127.5, 127.5)

    net = convert(m).eval()
    x = torch.rand(1, 3, 112, 112) * 2 - 1
    with torch.no_grad():
        traced = torch.jit.trace(net, x)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), color_layout=ct.colorlayout.RGB,
                             scale=1.0 / std, bias=[-mean / std] * 3)],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.author = "fal.ai (AuraFace-v1), converted by CueCoach tools/faceid"
    mlmodel.license = "Apache-2.0"
    mlmodel.short_description = "AuraFace-v1 face recognition embedding (512-D). Input: ArcFace-aligned 112x112 RGB."
    mlmodel.version = "fal.auraface.v1.fp16"
    mlmodel.user_defined_metadata["source"] = a.source
    mlmodel.user_defined_metadata["modelID"] = "fal.auraface.v1.fp16"

    # Parity: ONNX Runtime (fp32) vs Core ML (fp16) on identical uint8 images.
    sess = ort.InferenceSession(a.onnx, providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(0)
    cos = []
    for _ in range(a.checks):
        # Smooth random images (closer to faces than white noise).
        small = rng.integers(0, 256, size=(14, 14, 3), dtype=np.uint8)
        img = Image.fromarray(small).resize((112, 112), Image.BILINEAR)
        arr = np.asarray(img).astype(np.float32)
        ref_in = ((arr - mean) / std).transpose(2, 0, 1)[None]
        ref = sess.run(None, {inp.name: ref_in})[0].reshape(-1)
        got = np.asarray(mlmodel.predict({"face": img})["embedding"]).reshape(-1)
        cos.append(float(ref @ got / (np.linalg.norm(ref) * np.linalg.norm(got))))
    print(f"parity cosine onnx vs coreml-fp16: min {min(cos):.6f} mean {np.mean(cos):.6f}")
    if min(cos) < 0.999:   # every sample, not just the mean
        print("parity check failed", file=sys.stderr)
        return 1
    mlmodel.user_defined_metadata["parityCosineMean"] = f"{np.mean(cos):.6f}"
    mlmodel.save(a.out)
    print(f"wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
