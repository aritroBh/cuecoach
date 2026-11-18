#!/bin/sh
# Stage MLX weights into tools/vlm-bench/Models (gitignored) and push them into the bench app's Documents.
# Weights come from the local Hugging Face cache (huggingface-cli download <repo> fills it); nothing is committed.
# Usage: ./fetch-models.sh [device-udid ...]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/Models"
for repo in mlx-community/Qwen3.5-2B-MLX-4bit mlx-community/gemma-4-e2b-it-4bit; do
  name=${repo#*/}
  snap=$(ls -d "$HOME/.cache/huggingface/hub/models--${repo%%/*}--$name/snapshots/"* | head -1)
  mkdir -p "$here/Models/$name"
  cp -L "$snap"/* "$here/Models/$name/" 2>/dev/null || true
  rm -f "$here/Models/$name/README.md" "$here/Models/$name/.gitattributes"
done
for dev in "$@"; do
  for name in $(ls "$here/Models"); do
    xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer \
      --domain-identifier com.aritrobh.cuevlmbench --source "$here/Models/$name" --destination "Documents/Models/$name"
  done
done
