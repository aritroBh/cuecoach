# On-device VLM benchmark for post-shot keyframe analysis (D22)

Measured 2026-11-06 on two real phones, iOS 27.2: **iPhone 15 Pro Max** (iPhone16,2, 8 GB, perf gate) and
**iPhone 17 Pro Max** (iPhone18,2). Bench app: `tools/vlm-bench/` (standalone XcodeGen project,
`com.aritrobh.cuevlmbench`). Raw per-question results: `tools/vlm-bench/results/`.
Scope per SPEC §5.9: VLMs run only after a shot settles, never on the live path.

**TL;DR**
1. **No candidate can read table state from a keyframe.** On ball identity, cue-in-kitchen and
   "which pocket" all three models sit at or near a trivial constant-answer baseline on clean synthetic frames.
   Qwen lists all 15 balls nearly every time. Every model answers "not in kitchen" for all 20 frames.
   Verifying shot classification from pixels must stay with the deterministic detector + tracker.
2. **Labels (≤ 2 words) are the only task where a VLM helps.** Qwen3.5-2B 5/6, Gemma-4-E2B 4/6, Apple FM 3/6.
   With n = 6 this is a hint, not proof. Apple FM also tripped its safety guardrail on 2–8 of 54 prompts.
3. **Cost.** Apple FM: 0 MB, about 0.8 s (17 PM) to 2 s (15 PM) per answer. Qwen3.5-2B: +1.67 GB of weights,
   **4.4 GB peak** process memory, about 3 s (17 PM) / 9 s (15 PM, throttled) per answer. Gemma-4-E2B: +3.42 GB,
   4.4 GB peak, 1.8 s / 5.5 s.
4. **Recommendation:** keep **Apple Foundation Models** for text-only labelling, using the engine's numbers as
   input, not pixels. Keep the deterministic label fallback. Handle guardrail refusals as a fallback.
   **Don't adopt a third-party VLM.** It is not clearly better on the vision tasks, which is the bar D22 set.
   It would add 1.7–3.4 GB and a 4.4 GB memory peak on the 8 GB perf-gate phone. Revisit only if a model clears
   the vision baselines below on real keyframes.

---

## 1. Candidates and licenses

| Model | Runtime | Weights (disk) | License | Benchmarked? |
|---|---|---|---|---|
| Apple Foundation Models (iOS 27 system model, `.vision` + `.guidedGeneration` capabilities, context 8192) | `FoundationModels`, `@Generable` structs, image `Attachment` | 0 MB (in OS) | Apple SDK / OS terms | Yes |
| Qwen3.5-2B (`mlx-community/Qwen3.5-2B-MLX-4bit`, natively multimodal) | MLX Swift (`mlx-swift-lm` 3.31.4, `MLXVLM` `qwen3_5`) | 1,674 MB (4-bit, 6.2 bpw mixed) | **Apache-2.0** | Yes |
| Gemma-4-E2B-it (`mlx-community/gemma-4-e2b-it-4bit`) | MLX Swift (`gemma4`) | 3,417 MB | **Apache-2.0** (base `google/gemma-4-E2B-it`) | Yes (third candidate, swapped in for FastVLM) |
| Apple FastVLM-0.5B (`apple/FastVLM-0.5B`, `mlx-community/FastVLM-0.5B-bf16`) | MLX Swift (`fastvlm`) | ~1.2 GB bf16 | **apple-amlr** (Apple ML Research license: research use, not for products) | **No.** The license excludes product use |
| Qwen2.5-VL-3B-Instruct | MLX Swift | ~2 GB 4-bit | **qwen-research** (non-commercial) | **No.** License. (Qwen3.5-2B is the Apache successor) |

Licenses were read from the Hugging Face model cards on 2026-11-06.

## 2. Test set

`tools/vlm-bench/testset/generate.py` (`uv run generate.py`, seed 22) renders **20 synthetic keyframes** with
known layouts. There are 10 top-down frames and 10 perspective frames from the head end at 30/35/40/45/50°
pitch (pinhole camera, ball radius scales with depth). Balls are numbered solids and stripes plus the cue
ball, on 2–15 object balls. There are also **8 BEFORE|AFTER pair images**, in which ball N sits in the jaws
of a pocket in the AFTER frame. The 6 pockets are cycled, so 4 of the 8 are head pockets. Ground truth is
in `testset.json`. The images are rendered by us, so they are safe to publish.

| Question kind | n | Truth / scoring | Trivial baseline |
|---|---|---|---|
| `ballsOnTable`: object-ball numbers + cue present | 20 | exact set match; partial = Jaccard | "all 15" → 0 % exact, Jaccard 0.49 |
| `cueInKitchen` | 20 | bool (10 true / 10 false) | constant answer → 50 % |
| `pocketDrop` (pair image) | 8 | one of 6 pockets | constant "headLeft" → 25 %; random → 17 % |
| `shotLabel`: text description of a shot + keyframe → ≤ 2-word label | 6 | ≤ 2 words, no digits, and contains an on-topic keyword | n/a |

Each model gets the same system prompt (`BenchCore.Prompts`). Apple FM gets guided generation into
`@Generable` structs (enum for pockets). The MLX models get a JSON-only instruction. Their output is
extracted and **schema-validated** (`BenchCore.AnswerParser`: types, ranges 1–15, pocket enum). An invalid
answer scores as wrong. Decoding is greedy, with max 200 tokens and a fresh session per question. MLX
images are resized to fit 1024 px. Scoring logic is unit-tested (`cd tools/vlm-bench/BenchCore && swift test`).

## 3. Results

Each model ran in a separate app launch, so the peak-memory ledger is clean. There were two passes per
device. Pass 2 is in §3.3.

### 3.1 Accuracy (54 questions; identical answers on both phones for the MLX models, which use greedy decoding)

| Model | Overall | Balls exact (Jaccard) | Kitchen | Pocket | Label | Schema-valid |
|---|---|---|---|---|---|---|
| Apple FM, 15 PM | 28 % | 10 % (0.47) | 50 % (always "no") | 0 % (8 guardrail refusals) | 3/6 | 85 % |
| Apple FM, 17 PM | 26 % | 0 % (0.46) | 50 % (always "no") | 12 % (7× "sideRight") | 3/6 | 96 % |
| Qwen3.5-2B (both) | 39 % | 10 % (0.49, lists all 15 in 20/20) | 50 % (always "no") | 50 % (4/4 head pockets right, else "headRight") | **5/6** | 100 % |
| Gemma-4-E2B (both) | 31–33 % | 5–10 % (0.39–0.41) | 50 % (always "no") | 25 % (always "headLeft") | 4/6 | 100 % |

Labels produced:
- Qwen: "Break shot", "missed shot", "scratch shot", "razor-thin cut", "bank shot", "Snookered shot".
- Gemma: "rack smash", "early 8-ball" (has a digit, so it fails the no-numbers rule), "direct pocket",
  "perfect cut", "winning bank" / "Banker Shot", "snooker setup".
- FM: "Boom" / "Full Rack", "Miss" / "Clean break", "Corner Strike" (for a scratch), "Razor", "Bank Shot",
  "Snooker" / "Snooker Master". FM sometimes refused.

### 3.2 Performance, pass 1

| Model × device | Load | First token (median) | Latency median / p90 | Peak footprint | Free mem after load | Weights | Thermal start→end |
|---|---|---|---|---|---|---|---|
| Apple FM, 15 PM | 2.4 s (cold first request) | 1.90 s | 1.95 / 2.70 s | 40 MB in-app (the model runs in a system process, so its memory isn't attributable) | 6.1 GB | 0 | nominal → **serious** |
| Apple FM, 17 PM | 0.4 s | 0.75 s | 0.79 / 1.67 s | 41 MB in-app | 6.1 GB | 0 | nominal → nominal |
| Qwen3.5-2B, 15 PM | 5.5 s | 7.5 s | 9.4 / 14.4 s | **4,360 MB** | 4.3 GB | 1,674 MB | serious → serious (throttled throughout) |
| Qwen3.5-2B, 17 PM | 4.8 s | 2.0 s | 2.9 / 4.8 s | **4,362 MB** | 4.3 GB | 1,674 MB | nominal → nominal |
| Gemma-4-E2B, 15 PM | 2.3 s | 4.9 s | 5.5 / 6.7 s | **4,378 MB** | 3.2 GB | 3,417 MB | nominal → serious |
| Gemma-4-E2B, 17 PM | 2.0 s | 1.4 s | 1.8 / 2.9 s | **4,410 MB** | 3.2 GB | 3,417 MB | nominal → fair |

Notes:
- Prompt sizes: Qwen 760–1,270 tokens per question (most are image tokens). Gemma 500–530.
- The app bundle is 30.7 MB, which includes MLX. MLX weights would add 1.7 or 3.4 GB to the app.
- The peak of about 4.4 GB is the image prefill. It needs `com.apple.developer.kernel.increased-memory-limit`.
  That entitlement signs fine with the free Personal Team and raises the budget to about 6.1 GB on both
  phones. Without it, an 8 GB phone is at real jetsam risk.
- MLX load times use memory-mapped safetensors. They exclude a 0.4 s one-time Metal kernel compile, which
  is a bench-only cost (§4).

### 3.3 Performance, pass 2

Pass 2 was a back-to-back re-run of all three models on both phones (Qwen, then Gemma, then FM).
**Accuracy was identical to pass 1 for every model on both devices**, so greedy decoding is deterministic here.

| Model × device | Load | First token (median) | Latency median / p90 | Peak footprint | Thermal start→end |
|---|---|---|---|---|---|
| Apple FM, 15 PM | 2.7 s | 2.21 s | 2.22 / 3.55 s | 37 MB in-app | serious → serious |
| Apple FM, 17 PM | 1.7 s | 0.91 s | 0.91 / 1.83 s | 41 MB in-app | serious → serious |
| Qwen3.5-2B, 15 PM | 1.2 s (page cache warm) | 7.18 s | 8.51 / 14.07 s | 4,358 MB | serious → serious |
| Qwen3.5-2B, 17 PM | 1.2 s (warm) | 1.72 s | 2.82 / 4.80 s | 4,372 MB | nominal → fair |
| Gemma-4-E2B, 15 PM | 2.0 s | 5.65 s | 6.27 / 7.68 s | 4,379 MB | serious → serious |
| Gemma-4-E2B, 17 PM | 2.0 s | 1.45 s | 1.86 / 2.91 s | 4,407 MB | fair → serious |

The 15 Pro Max stayed at thermal state `serious` through every MLX run in both passes. Its MLX latencies
are therefore sustained, throttled numbers. That is realistic for a phone that has just run live tracking,
but it is not a cold best case. The 17 Pro Max is about 3× faster on MLX and about 2.4× faster on FM.
For a post-shot card with a balls-settle window of about 2 s, only Apple FM on the 17 PM fits. On the
15 PM, every model needs post-game or background scheduling, which SPEC §6.1 already requires
("post-game only, never concurrent with live tracking").

## 4. How it was built (reproducing)

```sh
cd tools/vlm-bench
./vendor.sh                      # pinned offline package sources -> Vendor/ (gitignored)
./fetch-models.sh <udid> ...     # weights from the local HF cache -> Models/ (gitignored) -> app Documents
xcodegen generate
xcodebuild -project CueVLMBench.xcodeproj -scheme CueVLMBench -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device process launch --device <udid> --terminate-existing com.aritrobh.cuevlmbench -- -model qwen3.5-2b
# models: apple-fm | qwen3.5-2b | gemma4-e2b; results -> Documents/results-<model>.json (+ results.json)
```

Deviations and workarounds, listed so a supervisor can check them:
- **Release configuration** was used instead of the default Debug, for fair MLX timing.
- **The 17 Pro Max was at the free-profile 3-app limit.** The head orchestrator removed OpenSound and
  OpenCane with the user's OK before the 17 PM runs.
- **No git dependency fetches.** SwiftPM clones of github stalled on this network (about 35 KB/s).
  `vendor.sh` assembles pinned sources from tarballs and the local SwiftPM cache:
  - mlx-swift-lm 3.31.4
  - mlx-swift 0.31.4, plus its mlx and mlx-c submodule commits
  - swift-transformers 1.4.0, trimmed to `Tokenizers` with an offline `HubApi`
    (`vendor-patches/HubApiLite.swift`). The bench therefore has **no network code path**.
- **The Metal Toolchain is not installed** (a ~700 MB download, not feasible on this link). mlx-swift
  precompiles only 9 kernel files and the rest are JIT. `vendor-patches/patch_mlx.py` compiles those 9 at
  runtime with `MTLDevice.newLibrary(source:)` (0.4 s, timed separately). A shipping build would use the
  normal precompiled metallib.
- **mlx-swift-lm 3.31.4 cannot load `gemma-4-e2b-it-4bit`**: `keyNotFound layers.15.self_attn.v_proj`.
  The cause: `sanitize()` drops K/V projections for KV-shared layers, but the backbone still builds them.
  `vendor-patches/patch_mlx_lm.py` builds those layers with `kvSharedOnly`. The backbone always passes
  `sharedKV` to them, so no math changes.
- Apple FM memory is in a system daemon, so the in-app footprint understates its real cost.

## 5. Limits of this benchmark

- The frames are **synthetic**: flat shading, clean colours, no glare, people or cues. Real keyframes are
  harder. Models that fail here will fail on real frames. Models that pass here still need real-frame checks.
- n is small: 6 label prompts and 8 pocket prompts. Label scoring by keyword is generous by design.
- The 15 PM stayed at thermal `serious` in both passes, so its latencies are sustained and throttled, not a
  cold best case. The 17 PM ran mostly at nominal or fair.
- Only greedy decoding and one prompt style were tried. Prompt engineering could move the label scores, but
  it is very unlikely to fix the chance-level perception.
