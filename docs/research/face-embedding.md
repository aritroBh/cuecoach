# Face embedding for player recognition: model and licence research

Status: research written 2026-11-06 for Phase 5 (Identity), branch `wt/identity`. **Decided 2026-11-08 (D25):
AuraFace-v1 recognition graph, integrated behind the on-device ship gate** — see §8.
Companion to `docs/research/mesh-identity.md` §6 (gating task `LIC-ID`, open question Q4).

## TL;DR

1. **Apple has no face-recognition API.** Vision detects faces, landmarks and capture quality. It gives no identity
   vector. Today's "face" path (`VisionFeaturePrintExtractor(kind: "face")`) runs the generic
   `GenerateImageFeaturePrintRequest` on an **unaligned, ungated** face box crop. Public evidence on generic
   foundation embeddings used for faces is poor (DINOv2 ViT-S zero-shot: about 65 % mean verification accuracy over
   LFW/CALFW/CPLFW/CFP-FP/AgeDB, where face models score 95–99 %) [FROUND]. We have **no evidence** that the Apple
   feature print is good enough to tell people apart by face. Treat it as a baseline to beat, not as a face model.
2. **Every well-known small face model is blocked for shipping.** The cause is the weights or their training data:
   InsightFace ArcFace/MobileFaceNet, EdgeFace, AdaFace/CVLFace, GhostFaceNets, FaceNet (VGGFace2/CASIA), and the
   ViT ports trained on MS1MV3. Code licences (MIT/BSD/Apache) are not the problem.
3. **Recommended candidate: AuraFace-v1 recognition graph only** (fal.ai, Apache-2.0 weights). Its card says it was
   trained on "commercially and publicly available data sources" so it can be used commercially [AURA]. It is a
   ResNet100 (LFW 99.65 %) with a 512-D output. A community Core ML fp16 port exists (~124 MB) [AURA-CML].
   Residual risk: fal does not name the training set, so provenance rests only on fal's claim. The same repo also
   ships InsightFace detector and landmark files, which are non-commercial. **Bundle only `glintr100.onnx`**, and use
   Apple Vision for detection and 5-point alignment.
4. **Fallback with the clearest grant, weaker provenance: dlib ResNet v1** (weights CC0/public domain, 128-D,
   LFW 99.38 %, ~22 MB) [DLIB]. Its training data includes FaceScrub (CC BY-NC-ND 3.0) and VGG face data plus web
   scrapes. The licensor's grant is clean, but the data is not.
5. **Before any model choice matters, fix the pipeline.** Crops must be 5-point aligned to the model template
   (112×112 ArcFace or 150×150 dlib), and gated by face size, yaw/roll and `faceCaptureQuality`. Thresholds must be
   calibrated **per `modelID`** with the local TAR@FAR / open-set benchmark in §6. The current single
   `SimilarityCalibration(threshold: 0.75)` for faces has no measured basis for any model.
6. **This needs a user decision.** Whether shipping AuraFace's "commercial dataset, unnamed" provenance in a public
   AGPL-planned repo (D21) is acceptable is a product and legal call (CLAUDE.md: ambiguity → ask). Until then, keep
   Q4's default: clothing + turn order + tap-to-bind, with face off.

---

## 1. What Apple gives us (iOS 27, on-device)

| Need | API | Use for us | Gap |
|---|---|---|---|
| Face boxes, roll/yaw | `DetectFaceRectanglesRequest` / `VNDetectFaceRectanglesRequest` | Find faces; reject steep yaw | — |
| Landmarks | `DetectFaceLandmarksRequest` (76-pt constellation: pupils, nose crest, outer lips) | **Derive the 5 alignment points** (2 eye centres, nose tip, 2 mouth corners) for a similarity warp to the model template | Points differ slightly from the RetinaFace/MTCNN 5-pt definitions the models were trained with; measure the effect in §6 |
| Capture quality | `DetectFaceCaptureQualityRequest` → `faceCaptureQuality` 0…1 ("better lit, sharper, more centrally positioned") [VFACEQ-DOC] | Gate enrolment frames and probes; pick best-of-N | Apple's docs do not say whether the score is absolute or only comparable within one subject; Apple's own sample ranks selfies of one person. Treat it as **relative**: best-of-N per track, plus a floor tuned in §6 |
| Identity embedding | **None** (`VNFaceObservation` has no identity vector) [VFACEOBS, F79961] | — | Needs a bundled Core ML model |
| Generic embedding | `GenerateImageFeaturePrintRequest` (iOS 18+) | Clothing; face **baseline** only | Not trained for identity; float distances are not cosine-calibrated |

Apple Photos' "People" recognition runs on-device, but Apple has no public API for it. iOS 26/27 API searches found
no face-identity addition. The last check used secondary sources, so re-check the iOS 27 Vision diff when Xcode
updates.

## 2. Candidate table

Accuracy numbers are as published by each source and are not re-measured. "IJB-C" means TAR@FAR=1e-4 unless noted.
ANE latency is an **estimate** for the A17 Pro (15 Pro / 15 Pro Max) from FLOPs, assuming 20–40 % effective ANE use
at fp16. Measure it on the device before relying on it.

| Model | Code licence | Weights licence | Training data (terms) | Size | Accuracy | Core ML path | ANE est. / face | Ship verdict |
|---|---|---|---|---|---|---|---|---|
| **AuraFace-v1** (fal) [AURA] | Apache-2.0 (inference via InsightFace MIT code; not needed) | **Apache-2.0** (repo `LICENSE.md`) | "Commercial dataset comprising face images from various sources", **not named** | ResNet100, ~65 M params; ONNX 261 MB fp32; Core ML fp16 ~124 MB [AURA-CML]; ~33–49 MB after 4–6-bit palettization (est.) | LFW 99.65, CFP-FP 95.19, AgeDB 96.10, CALFW 94.70, CPLFW 90.93; no IJB-C | **Done by others**: ONNX → onnx2torch → trace → coremltools, cos 0.99996 vs ONNX [AURA-CML]. Re-do ourselves as `mlprogram` from a pinned SHA | ~24 GFLOPs → **~4–10 ms** | **Candidate (recommended)**. Ship only the recognition graph. Ask fal in writing about data provenance. |
| **dlib ResNet v1** [DLIB] | Boost (dlib) | **CC0 / public domain** | ~3 M faces, 7,485 ids: FaceScrub (**CC BY-NC-ND 3.0** [FSCRUB]), "VGG dataset" (research terms), web scrapes | ~5.6 M params, 22 MB fp32, 128-D, 150×150 input | LFW 99.38 ± 0.27 | No direct port. dlib → Keras/TF converter [DLIB-CONV] → coremltools; or rebuild the ResNet-29 in PyTorch from dlib XML. Medium effort | ~2–3 GFLOPs → **~1–2 ms** | **Fallback.** Clean licensor grant, tainted data. Older and weaker on pose and low resolution |
| SFace (OpenCV Zoo) [SFACE, HF-SFACE] | Apache-2.0 | Apache-2.0 (zoo files) | Not stated by the zoo. The paper trains on CASIA-WebFace, VGGFace2, **MS-Celeb-1M (withdrawn 2019)** [SFACE-paper, MSCELEB] | ONNX 38.7 MB fp32, 9.9 MB int8 | 99.40 (zoo eval, LFW-style) | Easy: ONNX → coremltools (via onnx2torch) | ~1 GFLOP → **< 1 ms** | **Blocked** (unchanged from mesh-identity §6) until upstream names the training set |
| EdgeFace XS/S/Base (Idiap) [EDGE, EDGE-HF] | BSD-3-Clause | **CC BY-NC-SA 4.0** | WebFace260M (4M/12M subsets) — research-only | 1.77 M (XS) / 3.65 M (S) / 18 M (Base) | XS: LFW 99.73, IJB-C 94.85; S: LFW 99.78, IJB-C 95.63 | Easy (PyTorch, timm-style) | XS 0.15 GFLOPs → **< 1 ms** | **Blocked.** NC + SA conflicts with the AGPL plan (D21); data is research-only. Local research benchmarking only |
| AdaFace / CVLFace [ADA, CVL] | MIT | None stated; card: "follow the license of the training dataset" | CASIA, VGGFace2, MS1MV2/V3, WebFace4M/12M (all research / non-commercial) | IR18 24 M … IR101 | IR18-WebFace4M: LFW 99.53, IJB-C 94.99 | Easy | IR18 ~5 GFLOPs → ~2 ms | **Blocked** |
| GhostFaceNets [GHOST] | MIT | None separate | MS1MV2 / MS1MV3 (InsightFace, non-commercial) | small | LFW 99.65–99.78, IJB-C 92.7–94.9 | Easy (Keras) | < 1 ms | **Blocked** |
| InsightFace ArcFace / MobileFaceNet / buffalo packs [INSIGHT] | MIT | **Non-commercial research only**; buffalo_l needs a licence | MS1M / Glint360K / WebFace (non-commercial) | various | SOTA | Easy | < 1–10 ms | **Rejected** |
| FaceNet (davidsandberg) / facenet-pytorch / DeepFace Facenet512 / `nxp/facenet512-imx` [FNET, FNET-PT, NXP] | MIT | None stated upstream. The NXP card says "MIT", but the weights come from DeepFace/davidsandberg | VGGFace2 (Oxford has pulled the downloads [VGG2]), CASIA-WebFace | 23.5 M params, 512-D | LFW 99.65 (VGGFace2) | Easy | ~3 GFLOPs → ~1–2 ms | **Blocked.** A repackager's "MIT" label does not clean the weights |
| `gaunernst/vit_tiny…arcface_ms1mv3` [HF-VIT] | timm (Apache) | None stated | MS1MV3 | 5.5 M | — | Easy | ~1 ms | **Blocked** |
| Apple feature print on **aligned** crop | OS | OS (nothing bundled) | Apple | 0 MB | Unknown for identity; generic models score poorly on faces [FROUND] | Native | ~2–5 ms (est.) | **Clear licence, weak accuracy.** Baseline only |
| DINOv2 ViT-S (Meta) | Apache-2.0 | Apache-2.0 | LVD-142M (curated web) | 21 M | ~65 % mean zero-shot face verification [FROUND] | Easy | ~5 GFLOPs | **Not useful** zero-shot; fine-tuning needs face data we can't licence |
| Train our own on licence-clean data | — | ours | No large permissive face-identity dataset exists. DigiFace-1M (synthetic) is **non-commercial** [DIGI] | — | — | — | — | **Not feasible** near-term |

### Licence reasoning, briefly

- Weights are what we redistribute, so the weights licence controls. A permissive code licence never covers the
  weights unless it says so (InsightFace and EdgeFace both separate the two).
- When the weights carry no licence ("follow the dataset's licence", or nothing stated), the terms of the training
  data are the only terms that apply. All the big real-face datasets (MS1M, WebFace260M, Glint360K, VGGFace2,
  CASIA-WebFace, FaceScrub) are research-only, withdrawn, or NC. **Not legal advice.** In US law it is unsettled
  whether model weights are copyrightable or "derived" from their training data. The project's safe reading is
  "inherit the data terms" unless the licensor grants explicitly.
- Two weights sets carry an **explicit permissive grant from the licensor**: AuraFace (Apache-2.0, data claimed
  commercial) and dlib (CC0, data admittedly research/NC). AuraFace's claim covers both the weights and the data,
  which is why it ranks first.
- Repo compatibility: Apache-2.0 → AGPL-3.0 (D21) is compatible one-way. CC0 is compatible. CC BY-NC-SA is not:
  it adds a non-commercial restriction the AGPL forbids, and a ShareAlike that conflicts with it.
- BIPA (mesh-identity §7.4, R11) applies to *any* face template, whichever model makes it. A better model does not
  change the consent and retention obligations.

## 3. Recommendation (for the orchestrator and user)

1. **User decision first (new question Q17).** "Ship AuraFace-v1's recognition graph (Apache-2.0, trained on a
   commercial dataset fal does not name) in the public repo / app bundle? Alternative: dlib (CC0 weights,
   research-data provenance). Or keep face off for Phase 5." Recommended: AuraFace. Before release, email fal asking
   which dataset was used and for written confirmation, and record the answer in `docs/DECISIONS.md`.
2. **Never commit model binaries** (130 MB, and keeping the repo lean). Add a `tools/face_model/` script
   (`uv run`) that downloads `fal/AuraFace-v1@<commit>/glintr100.onnx` with a pinned SHA-256, converts it to a Core ML
   `mlprogram` (fp16, then a palettization trial), checks cosine ≥ 0.999 against ONNX Runtime on a synthetic tensor,
   and writes the `.mlpackage` into a git-ignored path that `project.yml` picks up. The download happens at build
   time on the developer's Mac. The app makes **zero network calls**. Ship Apache `LICENSE` and `NOTICE` text in the
   in-app acknowledgements.
3. **Do not copy** `scrfd_10g_bnkps.onnx`, `2d106det.onnx`, `1k3d68.onnx` or `genderage.onnx` from the fal repo. They
   are InsightFace's non-commercial models [AURA-ONNX].
4. **Pipeline changes (TDD in CueCore where pure):**
   - `FaceAligner` (pure, CueCore): 5 points → similarity transform → 112×112 ArcFace template (the standard
     `[38.29,51.70] [73.53,51.50] [56.03,71.74] [41.55,92.37] [70.73,92.20]`). Unit-test it on synthetic points
     (identity, rotation, scale, and a degenerate input → nil).
   - `FaceQualityGate` (pure): reject when the face is too small (inter-ocular distance < ~24 px in the source frame,
     an assumption to tune), |yaw| > ~35°, |roll| > ~25°, or quality is below the per-session best-of-N floor.
   - `CoreMLFaceEmbedder: EmbeddingExtracting` with `modelID = "fal.auraface.v1.fp16"`. The `modelID` already keeps
     templates from different models apart, so existing feature-print face templates become unusable and
     `needsReconsent` fires. That is correct.
   - Calibrate per model: `SimilarityCalibration` keyed by `modelID`. Use the τ from §6, never a shared 0.75.
5. **Latency budget.** One R100 face costs ~4–10 ms (est.). Within the 15 ms identity-face row for one face, but
   **not for 3 faces in one frame**. Spread faces over frames (check-in is 5 Hz anyway) or use palettized weights.
   If the 15 PM thermal gate fails, AuraFace runs at check-in only.
6. **Keep face a check-in cue.** At 2–4 m a face is often < 40 px tall and turned away at stroke time
   (mesh-identity §6). No model fixes that. Clothing + turn order stay the in-session cues.

## 4. Why the current Apple-feature-print face path is not acceptable as "face recognition"

- Generic image embeddings measure overall look (lighting, background, hair, glasses), not identity. Two players
  under the same table light can score closer than one player in two lights. The best public analogue, frozen
  DINOv2/CLIP, scores far below face models [FROUND].
- Crops are raw `DetectFaceRectanglesRequest` boxes: no alignment, no quality gate, no yaw filter
  (`VisionAdapters.swift`). mesh-identity §7.1 promises a `faceCaptureQuality ≥ 0.5` gate. It is not implemented.
- Threshold 0.75 (`Attribution.swift`, `SimilarityCalibration`) is a guess shared across models. For "guests never
  merged into a registered profile", the decision threshold has to come from a measured low-FAR operating point
  (§6). It cannot come from a constant.

## 5. Accuracy notes that matter for us

- LFW is saturated (all candidates are > 99 %), so it says little about our case. IJB-C TAR@FAR=1e-4 and
  CPLFW/CFP-FP (pose) are closer to it. AuraFace's CPLFW of 90.9 is lower than InsightFace R100's (~93–94), so
  expect it to be weaker on steep yaw [AURA-ONNX note: "a little less accurate than the InsightFace models"].
- Our problem is **small-gallery open-set identification**: 2–8 enrolled players, plus guests and bystanders who must
  come out "unknown". That is easier than million-scale search, but the error that hurts is a **false accept**
  (guest → registered profile, which corrupts that person's stats). So the operating point is chosen from FPIR
  (false-positive identification rate), not from rank-1 accuracy.
- Domain gap: enrolment uses the front camera at arm's length, matching uses the rear camera at 2–4 m with low,
  warm, single-source pool-hall light. Published numbers say nothing about this. Only §6 measures it.

## 6. Licence-clean local benchmark (on-device, consented, never committed)

### 6.1 Principles

- **No public face datasets.** LFW, IJB-C and the rest have their own terms, and the repo can't hold them. The
  benchmark runs only on **our own volunteers' consented captures**.
- Captures **never leave the iPhone** and are never committed. The only output is aggregate metrics (ROC points,
  τ per model, counts). No images, embeddings or per-person rows are exported.
- The metric code is pure Swift in `Packages/CueCore` (`FaceBenchMetrics`), test-first with synthetic score lists.
  Only the capture and embedding harness touches devices.

### 6.2 Consent and storage

- A separate **"Help test face recognition"** consent, distinct from the product consents. It names: what is
  captured (short face clips/frames), where it lives (this phone only, in app sandbox, file protection `.complete`,
  excluded from backup), how long (deleted automatically when the run ends, at most 7 days), and how to withdraw (a
  one-tap "delete my test captures" control; withdrawal deletes that subject's frames and every result computed
  from them). Record `{subjectCode, consentVersion, date}`. Subjects are random codes (S01…), never names.
- The harness lives in a **Debug-only target** (`#if DEBUG`, or a separate `CueCoachBench` scheme) so that capture
  code never ships in Release.
- `.gitignore` gets `bench-captures/`, `*.benchcap` and `*.mlpackage` as guards, even though captures should never
  reach the Mac.

### 6.3 Protocol

- **Subjects:** ≥ 10, ideally 15–20, varied in skin tone, glasses and facial hair. Include **look-alike pairs**
  (siblings, or same-hair/same-glasses pairs) on purpose. They are the realistic false-accept risk.
- **Enrolment set (gallery):** each subject enrols exactly as the product does: front camera, slow head turn, 8–12
  frames kept by the quality gate.
- **Probe set:** rear camera(s) on the table mount at 2, 3 and 4 m. Each subject (a) walks up and looks at the
  table (check-in), (b) takes 5 shots in normal stance, (c) wears a cap or glasses for one segment. Use two lighting
  conditions (the usual table light, plus brighter room light). Tag every probe with distance, yaw bucket,
  inter-ocular px, quality, lighting and accessory.
- **Unknowns:** for each run, hold out 30 % of subjects as **non-enrolled** (they appear only as probes) and rotate
  the split across folds. This tests "guests are never merged" directly.
- **Sessions:** at least two capture days per subject, so that same-day clothing and hair don't inflate genuine
  scores.

### 6.4 Metrics (computed on device)

1. **Verification ROC:** genuine pairs = (gallery template of S, probe of S); impostor pairs = (gallery of S, probe
   of T≠S), with look-alike impostors reported separately. Report **TAR @ FAR = 1e-2 and 1e-3**.
   - Resolution check: with 15 subjects × ~40 probes, impostor pairs number ≈ 15·14·40 = 8,400. FAR=1e-3 then rests
     on ~8 false accepts, which is the floor. **Do not report FAR=1e-4** from this data (pairs are correlated within
     a subject). 95 % CIs come from a **subject-level bootstrap** (resample subjects, not pairs).
2. **Open-set identification (the product decision):** for each probe, take the top-1 gallery match with cosine
   above τ and margin above m (current `IdentityMatcher` semantics). Report:
   - **FPIR**: the fraction of *non-enrolled* probes assigned to *any* registered player. This is the "guest merged"
     rate. **Target ≤ 0.5 %** (to confirm with the user).
   - **FNIR at that τ**: enrolled probes left "unknown" or misassigned. This is what falls back to tap or turn
     order, which is acceptable.
   - **Misidentification rate**: enrolled probe → wrong *registered* player. This is the worst error. **Target ≈ 0
     in the sample**, with an upper CI bound reported.
3. **Per-condition breakdown** by distance, yaw bucket, inter-ocular px and lighting. This picks the quality-gate
   floors (face size, yaw, quality), choosing the floor where misidentification drops to zero while coverage is
   still useful.
4. **Track-level aggregation:** a person track gives several probes. Measure the decision with best-of-N and
   mean-of-top-k over a 1–2 s window, because that is what attribution actually consumes.
5. **Latency and energy:** per-face ms (p50/p95) on the 15 Pro Max with detection running at 30 fps, plus thermal
   state after 10 minutes of check-in loops.

### 6.5 Arms compared (same captures, same harness)

| Arm | Ships? | Purpose |
|---|---|---|
| A0 Apple feature print, unaligned box crop (current code) | already in | Baseline: shows how far off today is |
| A1 Apple feature print, 5-pt aligned + gated | could ship | Is alignment alone enough? |
| A2 AuraFace-v1 fp16, aligned + gated | candidate | Recommended model |
| A3 AuraFace-v1 palettized (6-bit / 4-bit) | candidate | Size/latency vs accuracy |
| A4 dlib ResNet v1, aligned 150×150 | fallback | CC0 alternative |
| A5 EdgeFace-S / SFace | **never bundled** | Optional upper-bound reference, run only in the Debug bench target as local research use, if the user agrees; drop it if in doubt |

**Ship gate (proposal):** a face model is enabled only if, on the held-out fold, misidentification = 0 with upper
95 % CI ≤ 1 %, FPIR ≤ 0.5 %, and at least 60 % of check-in probes are decided (not "unknown") at 2–3 m. Otherwise
face stays off and Phase 5 runs on clothing + turn order + tap, as Q4 already defaults.

### 6.6 Outputs and retention

- `bench-result-<date>.json`: arms, τ/m per arm, ROC points, FPIR/FNIR, per-condition table, latency. No subject
  codes beyond counts. The orchestrator may commit this aggregate file. It holds no biometric data.
- On run end (or after 7 days, or on withdrawal), the harness deletes all frames and embeddings, and the deletion is
  verified by a unit test of the store's `deleteAll()`, as for `RecognitionData`.

## 7. Open items

- Q17 (new): approve AuraFace-v1 (or dlib, or keep face off) for bundling; set the FPIR target.
- Ask fal: which dataset trained AuraFace-v1, and do its terms allow weight redistribution? Ask zhongyy/OpenCV which
  data trained `face_recognition_sface_2021dec` (still open from mesh-identity Q4).
- Verify Apple's `faceCaptureQuality` semantics (relative vs absolute) on our captures, as §6.4.3 does.
- Re-check the iOS 27 Vision API diff for any new face-identity capability.

## 8. Integration record (D25, 2026-11-08)

| Item | Value |
|---|---|
| Repo / commit | `fal/AuraFace-v1` @ `af6d057c9b0ec4071d4c49c80e3539258798b609` |
| File used | `glintr100.onnx` only, sha256 `a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60` |
| Licence | Apache-2.0 (`LICENSE.md` sha256 `609e2cb599f84aaa41d8ef29d8fdb04d164fab22e8d9292ca34a599d0f56a338`); see `THIRD_PARTY_NOTICES.md` |
| Never fetched | `scrfd_10g_bnkps.onnx`, `2d106det.onnx`, `1k3d68.onnx`, `genderage.onnx` (F1/F3) |
| Fetch + convert | `tools/faceid/fetch_auraface.sh` → `convert_auraface.py` (uv, exact pins + `convert_auraface.py.lock`, run `--locked`; coremltools 9.0, torch 2.15.0, onnx 1.23.2, onnx2torch 1.5.15, onnxruntime 1.31.1, numpy 2.3.5, pillow 13.0.0; locked re-run reproduced parity min 0.999963): ONNX → onnx2torch → trace → Core ML ML Program FP16, iOS 17+ |
| Output | `CueCoach/Resources/Models/FaceEmbedding.mlpackage` (~125 MB, gitignored). Input `face` 112×112 RGB image (normalisation folded in), output `embedding` 512 floats |
| Parity | ONNX Runtime fp32 vs Core ML fp16, 8 random images: min cos 0.99996, mean 0.99997 |
| modelID | `fal.auraface.v1.fp16` (feature-print face templates are unusable → re-consent) |
| Pipeline | Vision `DetectFaceLandmarksRequest` → 5 points (eye centroids, nose centroid, outer-lip extremes) → least-squares similarity to the ArcFace 112 template → `FaceQualityGate` (inter-ocular ≥ 24 px, |yaw| ≤ 35°, |roll| ≤ 25°, `DetectFaceCaptureQualityRequest` ≥ 0.5) → `FaceEmbeddingExtractor` (Core ML, `.cpuAndNeuralEngine`, off the main actor, L2-normalised) |
| Without the model | App builds and runs; `FaceEmbeddingExtractor.bundled()` is nil, face consent can't be registered, face matching off |
| Ship gate (F6) | `FaceBenchmark.evaluate`: ≥ 10 consenting volunteers, ≥ 3,000 impostor pairs, TAR ≥ 0.90 at FAR 1e-3 (proposed target, user to confirm). Embeddings RAM-only for the run; only an aggregate `FaceShipGateRecord` is kept. `.shooterOnly` is honoured only when the record's modelID matches the templates' model |
| Simulator latency | 41 ms / face (simulator has no ANE; measure on the 15 Pro Max) |

Ship gate as implemented (D28): volunteers are split into two disjoint halves (≥ 10 each, so ≥ 20 volunteers with
≥ 4 usable crops). The calibration half fixes the threshold: halfway between the impostor-side limit (stricter of FAR 1e-3 and
open-set FPIR ≤ 0.5 %) and the genuine-side limit (where calibration TAR would fall to 0.90); the
report half, never seen during calibration, must show TAR ≥ 0.90, FPIR ≤ 0.5 % and zero misidentifications. The
record keeps 95 % Wilson bounds (TAR lower, FPIR and misidentification upper) and coverage (enrolled probes decided
correctly). Wilson bounds treat probes as independent; a subject-level bootstrap is the stricter follow-up.

Benchmark consent can only be made by `FaceBenchConsentFlow.grant` (the consent screen's "Agree") and is checked
against the flow's record, so a withdrawn grant stops further captures; runs are purged when expired on launch and on
every return to the foreground. The tap "guest margin" (0.1) is a documented heuristic: resemblance cannot prove who
produced a vector, so with an unmodelled guest present nothing is learned at all (D28).

**Release blocker (not code):** fal has not confirmed AuraFace-v1's training data in writing. The model card says
"commercially and publicly available data sources" without naming them. Before any release that bundles the model,
get written confirmation from fal of the dataset and its redistribution terms, and record it in docs/DECISIONS.md.

Not yet measured: ANE latency on device, the A0–A5 arms, and a real benchmark run.

## Sources

| Key | Source |
|---|---|
| AURA | fal/AuraFace-v1 model card + LICENSE.md (Apache-2.0) — https://huggingface.co/fal/AuraFace-v1 |
| AURA-CML | RuiSumida/AuraFace-v1-CoreML (fp16 neuralnetwork, ~124 MB, conversion + cos 0.999956) — https://huggingface.co/RuiSumida/AuraFace-v1-CoreML |
| AURA-ONNX | imagent/auraface-onnx (recognition graph only; notes the InsightFace detector/landmark files are non-commercial) — https://huggingface.co/imagent/auraface-onnx |
| DLIB | davisking/dlib-models README (public domain / CC0; ~3 M faces, 7,485 ids; FaceScrub, VGG, scraped; LFW 99.38) — https://github.com/davisking/dlib-models |
| DLIB-CONV | ksachdeva dlib → Keras/TF converter — https://github.com/ksachdeva/dlib-to-tf-keras-converter |
| FSCRUB | FaceScrub page (CC BY-NC-ND 3.0) — https://malea.winkler.site/facescrub.html |
| SFACE | OpenCV Zoo SFace README (Apache-2.0, no training set named) — https://github.com/opencv/opencv_zoo/blob/main/models/face_recognition_sface/README.md |
| HF-SFACE | opencv/face_recognition_sface files (38.7 MB fp32, 9.9 MB int8) — https://huggingface.co/opencv/face_recognition_sface |
| SFACE-paper | Zhong et al., SFace (CASIA-WebFace, VGGFace2, MS-Celeb-1M) — https://arxiv.org/abs/2205.12010 |
| MSCELEB | MS-Celeb-1M withdrawn (see mesh-identity.md source list) |
| EDGE | otroshi/edgeface (code BSD-3-Clause; sizes, LFW) — https://github.com/otroshi/edgeface |
| EDGE-HF | Idiap/EdgeFace-XS-GAMMA card (CC BY-NC-SA 4.0; WebFace260M; IJB-C 94.85) — https://huggingface.co/Idiap/EdgeFace-XS-GAMMA |
| ADA | mk-minchul/AdaFace (MIT; checkpoints per dataset, IJB-C) — https://github.com/mk-minchul/AdaFace |
| CVL | minchul/cvlface_* cards ("follow the license of the training dataset") — https://huggingface.co/minchul/cvlface_adaface_ir18_webface4m |
| GHOST | HamadYA/GhostFaceNets (MIT; MS1MV2/V3) — https://github.com/HamadYA/GhostFaceNets |
| INSIGHT | deepinsight/insightface License section (models non-commercial research only) — https://github.com/deepinsight/insightface |
| FNET | davidsandberg/facenet (MIT code; VGGFace2/CASIA models, no weights licence) — https://github.com/davidsandberg/facenet |
| FNET-PT | timesler/facenet-pytorch — https://github.com/timesler/facenet-pytorch |
| NXP | nxp/facenet512-imx card (weights from DeepFace) — https://huggingface.co/nxp/facenet512-imx |
| VGG2 | Oxford VGGFace2 page ("download links … no longer available") — https://www.robots.ox.ac.uk/~vgg/data/vgg_face2/ |
| HF-VIT | gaunernst/vit_tiny_patch8_112.arcface_ms1mv3 — https://huggingface.co/gaunernst/vit_tiny_patch8_112.arcface_ms1mv3 |
| DIGI | microsoft/DigiFace1M ("non-commercial research") — https://github.com/microsoft/DigiFace1M |
| FROUND | Chettaoui, Damer, Boutros, "FRoundation: Are Foundation Models Ready for Face Recognition?" — https://arxiv.org/abs/2410.23831 |
| VFACEQ-DOC | Apple, `VNDetectFaceCaptureQualityRequest` — https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest |
| VFACEOBS, F79961 | see mesh-identity.md source list |
| WEBFACE | WebFace260M (research-only access, secondary sources) — https://arxiv.org/abs/2204.10149 |
