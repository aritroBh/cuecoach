"""Patch vendored mlx-swift-lm 3.31.4: Gemma 4 E2B/E4B KV-shared layers.

sanitize() drops k_proj/v_proj/k_norm for KV-shared decoder layers (they reuse an earlier layer's K/V and
the backbone always passes `sharedKV` to them), but the backbone still builds those layers with local K/V
projections, so loading mlx-community/gemma-4-e2b-it-4bit fails with keyNotFound(...layers.15.self_attn.v_proj).
Build KV-shared layers with `kvSharedOnly: true` so the module tree matches the sanitized weights.
Usage: python3 patch_mlx_lm.py <Vendor/mlx-swift-lm>
"""
import sys
from pathlib import Path

p = Path(sys.argv[1]) / "Libraries" / "MLXVLM" / "Models" / "Gemma4.swift"
s = p.read_text()
old = """        self._layers.wrappedValue = (0 ..< config.hiddenLayers).map {
            Gemma4TextDecoderLayer(config: config, layerIdx: $0)
        }"""
new = """        let firstSharedLayer = config.hiddenLayers - config.numKVSharedLayers  // CueVLMBench patch
        self._layers.wrappedValue = (0 ..< config.hiddenLayers).map {
            Gemma4TextDecoderLayer(
                config: config, layerIdx: $0,
                kvSharedOnly: firstSharedLayer > 0 && $0 >= firstSharedLayer)
        }"""
assert s.count(old) == 1, "Gemma4.swift layout changed"
p.write_text(s.replace(old, new))
print("patched", p)
