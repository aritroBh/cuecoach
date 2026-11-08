# Third-party notices

## AuraFace-v1 face recognition model (optional, not in this repository)

- **What:** the face-recognition graph `glintr100.onnx` from AuraFace-v1 by fal.ai, converted on the developer's
  Mac to Core ML (FP16) as `CueCoach/Resources/Models/FaceEmbedding.mlpackage`. The converted model (~124 MB) is
  gitignored and is never committed; `tools/faceid/fetch_auraface.sh` fetches and converts it.
- **Source:** Hugging Face `fal/AuraFace-v1`, commit `af6d057c9b0ec4071d4c49c80e3539258798b609`.
  - `glintr100.onnx` sha256 `a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60` (260,694,151 bytes)
  - `LICENSE.md` sha256 `609e2cb599f84aaa41d8ef29d8fdb04d164fab22e8d9292ca34a599d0f56a338`
- **Licence:** Apache License 2.0 (the repository's `LICENSE.md`). Copyright fal.ai. The model card states it was
  trained on commercially available data sources; the dataset is not named (see `docs/research/face-embedding.md`).
- **Modifications:** format conversion only (ONNX → PyTorch trace → Core ML ML Program, FP16 weights, input
  normalisation folded into the image input). Parity vs ONNX Runtime: mean cosine 0.99997.
- **Not used:** the same repository's `scrfd_10g_bnkps.onnx`, `2d106det.onnx`, `1k3d68.onnx` and `genderage.onnx`
  (InsightFace detector / landmark / attribute models, non-commercial). They are never downloaded. Face detection
  and landmarks come from Apple Vision.

Apache License 2.0 text: https://www.apache.org/licenses/LICENSE-2.0
