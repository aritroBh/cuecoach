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

The full licence text ships in the app bundle as `CueCoach/Resources/Licenses/AuraFace-v1-LICENSE.md` (the verified
copy of the repository's `LICENSE.md`). Training-data provenance: fal states commercially available sources but does
not name them; written confirmation from fal is still pending (docs/research/face-embedding.md §7).

## Astryx design system, Apple package (vendored in `Packages/Astryx`)

- **What:** the SwiftUI views and theme tokens of Meta's Astryx design system (`packages/native/apple`, products
  `Astryx` and the contract types of `AstryxNative`), used for every screen and overlay (decision D34).
- **Source:** github.com/meta/astryx, commit `86fcdd3f0a9c46af063cc25c156382a30a2c9b42` (2026-11-09).
- **Licence:** MIT. Copyright (c) 2026 Meta Platforms, Inc. Full text in `Packages/Astryx/LICENSE`; the app bundle
  ships a copy as `CueCoach/Resources/Licenses/Astryx-LICENSE.txt`. Meta's copyright headers are kept in every file.
- **Modifications (zero-network, iOS 27):**
  - Left out: the JavaScriptCore logic host (`AstryxNative/Logic`), the wire view (`Astryx/Wire`), `Avatar` and
    `AvatarStatusDot` (remote `src` images via `AsyncImage`, `href` links), `Thumbnail` (remote `src` via
    `AsyncImage`), every theme except `Theme.default`, the package tests and the page templates.
  - Kept from the wire: only the generated value types the contracts need (`AstryxWire.swift`: `AstryxValue`,
    `AstryxAction`; `AstryxNode.swift`), which are plain `Codable` data with no transport.
  - Removed every link: `Button`, `Item` and `ListItem` no longer take `href` and never build a `Link` or an
    `OpenURLAction`; `Base/SafeDestination.swift` (URL parsing for links) is deleted; `Card` loses its wire-tree
    initializer; `Icon` loses its avatar-status preference.
  - iOS only (`platforms: [.iOS("27.0")]`, Swift 6 language mode); the AppKit imports are removed.
  - `PrivacyAuditTests` scans `Packages/Astryx/Sources` as shipped code and forbids `AsyncImage`, `Link(destination:`,
    `OpenURLAction`, `.openURL` and any `URL(string:` other than the Settings deep link.
