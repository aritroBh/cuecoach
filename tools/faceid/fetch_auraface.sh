#!/usr/bin/env bash
# Fetch the AuraFace-v1 *recognition graph only* (Apache-2.0) at a pinned commit, verify it, and convert it to
# Core ML (FP16) at CueCoach/Resources/Models/FaceEmbedding.mlpackage (gitignored: ~124 MB).
#
# Runs on the developer's Mac at build-prep time. The app itself makes zero network calls; without the model it
# builds and runs with face matching off. See docs/research/face-embedding.md (D25) and THIRD_PARTY_NOTICES.md.
#
# Never downloads scrfd_10g_bnkps.onnx, 2d106det.onnx, 1k3d68.onnx or genderage.onnx from the same repo:
# those are InsightFace's non-commercial detector/landmark/attribute models (face-embedding.md F1/F3).
# Detection and 5-point landmarks come from Apple Vision instead.
set -euo pipefail

REPO="fal/AuraFace-v1"
COMMIT="af6d057c9b0ec4071d4c49c80e3539258798b609"
GRAPH="glintr100.onnx"
GRAPH_SHA256="a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60"
LICENSE_SHA256="609e2cb599f84aaa41d8ef29d8fdb04d164fab22e8d9292ca34a599d0f56a338"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cache="${AURAFACE_CACHE:-$HOME/Library/Caches/CueCoach/auraface/$COMMIT}"
out="$root/CueCoach/Resources/Models/FaceEmbedding.mlpackage"
mkdir -p "$cache" "$(dirname "$out")"

fetch() {   # fetch <file> <sha256>
  local f="$1" want="$2" dst="$cache/$1"
  if [[ -f "$dst" ]] && [[ "$(shasum -a 256 "$dst" | cut -d' ' -f1)" == "$want" ]]; then return 0; fi
  curl -fL --retry 3 -o "$dst.part" "https://huggingface.co/$REPO/resolve/$COMMIT/$f"
  local got; got="$(shasum -a 256 "$dst.part" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then rm -f "$dst.part"; echo "sha256 mismatch for $f: $got != $want" >&2; exit 1; fi
  mv "$dst.part" "$dst"
}

fetch "$GRAPH" "$GRAPH_SHA256"
fetch "LICENSE.md" "$LICENSE_SHA256"

uv run --script "$here/convert_auraface.py" --onnx "$cache/$GRAPH" --out "$out" \
  --source "$REPO@$COMMIT/$GRAPH sha256:$GRAPH_SHA256"
du -sh "$out"
echo "Done. Run 'xcodegen generate' so the project picks up $out."
