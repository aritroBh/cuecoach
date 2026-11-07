# Perception research: camera to table + balls (SPEC §5.1–5.3, D12)

Compiled 2026-11-06. This is research and a design proposal. It contains no code. Every external claim cites a key from **Sources** (§11). "Est." marks numbers I derived or extrapolated; they still need measuring on the 15 Pro Max (D6 perf gate). "Unverified" marks claims I could not confirm against a primary source.

**TL;DR**
1. **Two calibration modes.** In tripod mode (the default), a 2–4 s ARKit/LiDAR scan runs first. After that the app uses a plain `AVCaptureSession` at 60 fps with a fixed calibration, and CoreMotion plus cheap edge checks watch for drift. In handheld mode, ARKit world tracking supplies a pose and metric scale on every frame.
2. **Table size (D12)** comes from three independent metric sources: LiDAR plane distance, ARKit's metric world scale, and the apparent size of the 57.15 mm balls. These are fused by inverse variance, then snapped to 7/8/9 ft or used directly. Planar features alone (pockets, diamonds) cannot give scale, because every table is 2:1.
3. **Ball centres sit on a plane at z = R = 28.575 mm.** The app uses a ball-plane homography `H_R = K[r1 r2 (R·r3 + t)]`, not the cloth homography, and applies an analytic sphere-projection bias correction.
4. **Detector: licensing blocks the spec's "Ultralytics" choice for a permissively licensed repo.** Ultralytics YOLO11/YOLO26 are AGPL-3.0, and that includes trained weights. The recommendation is a small CenterNet-style heatmap net that we write ourselves and run on a rectified table crop. YOLOX (Apache-2.0) or MIT-YOLOv9 is the fallback. **User decision needed (Q1).**
5. **Data: render our own.** We use Blender (we own its output) driven by our physics scenes, with labels for free. Roboflow sets are mostly CC BY 4.0 per their listings. We do not commit their images. We keep only a manifest and a download script.
6. **TDD is mostly camera-free.** Homography, size estimation, the tracker, identity smoothing and the segmenter live in `CueCore`. They are tested against `Simulator` traces sampled at 60 Hz with injected noise and dropouts. Replay QA runs `.mov` clips with JSON ground truth through the full pipeline.

---

## 1. Constraints that shape the design

| Constraint | Consequence for perception |
|---|---|
| Zero network calls (SPEC §2) | Models are bundled. All training happens on the Mac. Dataset downloads are dev-time only, in `tools/`, never in the app. |
| Free Personal Team | Camera, ARKit, LiDAR depth, CoreMotion and Core ML need only `Info.plist` usage strings (`NSCameraUsageDescription`, plus `NSMotionUsageDescription` if motion activity is used). None needs a restricted entitlement. |
| iPhone 15 Pro / Pro Max, A17 Pro | The Neural Engine is rated at 35 TOPS [A17]. Capture options are 4K at 24–60 fps, 1080p at 25–60 fps, and slo-mo 1080p at 120/240 fps. The main lens is 24 mm f/1.78, the ultra-wide 13 mm at 120°, and LiDAR is present [SPECS15]. |
| ≥30 fps detector, 60 fps overlay (§5.2, §5.6) | Run the detector at 30 Hz and the tracker/refinement at 60 Hz (§6). |
| Phase 3 gate | ≥30 fps on the 15 Pro, ball identity ≥95% on held-out video, and correct shot start/end in replays. |
| Public repo, no footage (D5) | Real test video lives outside git. Only synthetic renders and manifests are committed. |
| Physics ships in CueCore (D8) | `Simulator` traces are the ground truth for tracker and segmenter tests. |

## 2. Table geometry facts we rely on

| Item | Value | Source |
|---|---|---|
| Ball diameter | 2¼ in (+0.005 in) = 57.15 mm (+0.127 mm) | [WPA-EQ] |
| 9 ft playing surface (nose to nose) | 100 × 50 in (+⅛ in) | [WPA-EQ] |
| 8 ft playing surface | 92 × 46 in (+⅛ in). An 88 × 44 in "undersized 8" also exists. | [WPA-EQ], [AZ-BAR] |
| 7 ft (bar box) | **Not in the WPA spec.** Sources disagree: 76 × 38 [WIKI-TABLE] and 80 × 40 [AZ-BAR] are both cited. | Conflict |
| Cushion nose height | 62.5–64.5% of ball diameter, which is ≈ 35.7–36.9 mm | [WPA-EQ] |
| Corner / side pocket mouth | 4.5–4.625 in / 5–5.125 in | [WPA-EQ] |
| Sight spacing | 12.5 in on 9 ft, 11.5 in on 8 ft, which is L/8 | [WPA-EQ] |
| Ball speeds | Slow shot ≈ 3 mph, medium ≈ 7 mph, fast ≈ 12 mph, power ≈ 20 mph. A pro break is 25–30 mph (11–13 m/s). | [DD-SPEED], [DD-BREAK] |

Consequences:
- **The 7 ft preset is ambiguous.** Bar boxes vary by about 5%. `TableSize.sevenFoot` hard-codes 80 × 40 in. I propose that a measured length is used directly when it falls more than 2% from every preset, which D12 already allows ("or is used directly"). `TableSpec` should take arbitrary `length`/`width`.
- **The cushion-nose lines sit at about 1.27 R above the cloth**, close to the ball-centre plane at 1.0 R. Rail lines detected in the image belong to a raised plane, not the cloth. The model must treat them that way, or the homography picks up a ~36 mm parallax error. That error is several mm on the table at steep viewing angles.
- **Motion per frame at 60 fps:** 1.3 m/s (3 mph) moves 2.2 cm, or 0.4 ball diameter. 5.4 m/s (12 mph) moves 9 cm (1.6 D). A 13 m/s break moves 22 cm (3.8 D). Tracking a break at 60 fps needs physics-aided prediction (§5.3).

## 3. Calibration design

### 3.1 Sensors available

| Sensor / API | What it gives | Notes | Source |
|---|---|---|---|
| `AVCaptureDevice.builtInLiDARDepthCamera` (iOS 15.4+) | Absolute depth. Streaming depth is up to 320×240, photo depth up to 768×576, video up to 4032×3024. | An ML model fuses sparse LiDAR with the wide camera. Turn **filtering off** for CV so low-confidence points are dropped. Enable depth delivery only after the output is attached to the session. One forum thread reports that synchronized depth and video sometimes stop arriving (unresolved). Frame rates per format are not documented, so query `videoSupportedFrameRateRanges` at runtime. | [WWDC22-LIDAR], [AV-LIDAR], [AV-LIDAR-DOC], [FORUM-SYNC] |
| ARKit `sceneDepth` + plane detection | 256×192 depth with a confidence map, a metric world-tracking pose on every frame, and `ARPlaneAnchor`s | Check support with `supportsFrameSemantics(.sceneDepth)`. Pick the video format from `supportedVideoFormats` (the first entry is the default). A 60 fps format must be enumerated on the device. LiDAR range is usually quoted as about 5 m (unverified secondary source). | [WWDC22-LIDAR], [ARKIT-DEPTH], [ARKIT-FS], [MED-5M] |
| `AVCaptureDevice` camera intrinsics delivery | `K` per frame | This makes pose recovery from a homography well-posed apart from scale. | Apple API (no external claim) |
| CoreMotion (`CMMotionManager`) | Attitude and acceleration | Detects a tripod bump in under 100 ms (est.). Needs no entitlement. | Apple API |
| Vision | Contours, rectangles, body pose, trajectories | `VNDetectTrajectoriesRequest` assumes a tripod and a static background. It is stateful and needs timestamped buffers. Treat it only as a cross-check for fast balls. | [VN-TRAJ], [VN-TRAJ2] |

### 3.2 Pipeline (tripod mode, default)

1. **Coarse cloth region.** Seed at the image centre and region-grow on the dominant chroma (cloth is the largest uniform saturated area). This runs as a GPU compute kernel. Output: a cloth mask and its convex hull.
2. **Rail lines and pockets.** Take edges on the mask boundary and fit four cushion-nose lines with RANSAC. Pockets show up as dark notches: four at the line intersections and two at the long-rail midpoints. This is the same idea pix2pockets uses (RANSAC on the table sides, homography to a bird's-eye template, 0.4 cm ball location error from a single image) [PIX2P]. An optional keypoint head (6 pockets plus 18 diamonds), trained on synthetic data, makes this robust to occlusion.
3. **Pose up to scale.** With `K` known, solve the PnP/homography for `[R | t]`. Pocket mouths and nose lines use z = 0.635·2R. The pose comes out with an unknown scale `s` (the table length).
4. **Metric scale (D12).** Fuse three estimators, each with its own variance:
   - **LiDAR:** robust plane fit on unfiltered 768×576 photo depth (taken from a photo capture during the scan) or on ARKit `sceneDepth` with confidence = high. This gives the metric camera-to-cloth distance, so `s`.
   - **ARKit world scale:** for the 2–4 s scan, run an ARKit session and raycast the six pocket image points onto the detected horizontal plane. The pocket-to-pocket distances come out in metres.
   - **Ball size:** for each detected ball, run a sub-pixel limb fit on a full-resolution crop. Use a 12 MP still from the photo output so balls span 40–120 px (est.). The apparent diameter gives metric range Z ≈ f·2R/d. With N balls, the error per ball is about 1–2% (est., at ±0.5 px on 40 px) and falls roughly as 1/√N. A rack of 15 gives under 1%. This path also works without LiDAR, for example on future non-Pro devices or when depth fails.
   - **Fuse and snap:** inverse-variance mean of L (also W, checked against W ≈ L/2 ± 2%). Snap to {7, 8, 9 ft} when within ±2% of a preset. Otherwise use the measured value directly and show the table icon with a "custom" ring. Neighbouring presets differ by 9–15% (80/92/100 in), so snapping is robust once σ(L) < 1.5%.
5. **Homographies.** `H_cloth = K[r1 r2 t]` for cloth-level things (pocket capture, shadows). **`H_R = K[r1 r2 (R·r3 + t)]`** is used for all ball detections (SPEC §5.1 plane offset). The overlay renders through `H_R⁻¹` as well, since lines are drawn at ball-centre height.
6. **Sphere-projection bias.** The centre of a sphere's image ellipse is *not* the image of the sphere's centre. The offset grows with off-axis angle and ball size. With `K` and Z known, correct analytically (closed form from the sphere's tangent cone). This is a pure function and goes in CueCore.
7. **Quality metrics.** Pocket reprojection RMS (px), rail-line residual (px), the metric-estimator disagreement (%), and the expected table-plane error at the far corners (mm, by error propagation). The debug HUD shows them behind the dev toggle (D9).
8. **Continuous validation.** (a) A CoreMotion attitude change above about 0.3° marks the calibration *suspect* immediately. (b) Every rest period, and at least once per second, a cheap edge pass on the rail lines runs. A mean residual above 3 px for 2 s marks the calibration *stale*, and the UI shows a pulsing calibrate icon (no text). (c) Ball-at-rest positions should stay put. A coherent shift across all balls means the camera moved, not the balls. (d) Small drift is re-fit silently from the rail lines without user action.
9. **Fallback.** The user taps the 4 corner pockets (SPEC). The app refines with the rail lines, then takes scale from balls or LiDAR as above. If no metric source is available, it uses the user's preset pick (D7 visual picker).

### 3.3 Handheld mode

The app runs ARKit world tracking for the whole session. Each `ARFrame` brings a metric camera pose, so `H_R` is recomputed per frame from the anchored table plane plus the table rectangle fixed at calibration. Accuracy is degraded (SPEC allows this): pose jitter, motion blur, and ARKit's own video formats. Ball detection is unchanged. This mode cannot be fused across the mesh with the same confidence, so its detections are down-weighted.

### 3.4 Why the scan is not ARKit for the whole session (tripod)

ARKit owns the camera and restricts you to its video formats. It costs VIO CPU/GPU for a camera that does not move, and it adds thermal load across the 1-hour Phase 9 test. A short ARKit/LiDAR scan followed by a plain `AVCaptureSession` (wide camera, 60 fps, fixed manual exposure) gives full control of exposure and format. This is a hypothesis and must be measured in the Phase 3 spike (R4).

## 4. Ball detection and identification

### 4.1 Camera settings

- **Format:** 1920×1440 or 1920×1080 at 60 fps from `builtInWideAngleCamera` [SPECS15]. Est.: a 9 ft table filling the frame puts a far-rail ball at about 20–40 px across at 1080p, which is enough. 4K doubles the bandwidth with no detection benefit. Full resolution is used only for calibration stills.
- **Exposure:** custom exposure of ≤ 1/250 s, ISO raised as needed. At 3 m/s that limits blur to about 1.2 cm, versus 5 cm at 1/60. Lock white balance after calibration so the colour classifier sees stable hues.
- **120 fps option:** slo-mo 1080p at 120/240 fps exists [SPECS15], but switching formats at stroke start causes a stream interruption. It would have to be the session format from the start. This is open question **Q3**.

### 4.2 Detector options and licenses

| Option | License | Core ML path | Fit |
|---|---|---|---|
| **Ultralytics YOLO11 / YOLO26** | **AGPL-3.0, including trained models**, or a paid Enterprise license [UL-FORUM], [RF-LIC] | Native `format="coreml"` export: `quantize=8` (w8a16 palettized), `nms=False` for YOLO26's NMS-free head. Measured **YOLO26n detect at 640: 3.7 ms on CPU+ANE, iPhone 17 Pro, iOS 27.0.1** [UL-COREML] | Best tooling. YOLO26 adds STAL/ProgLoss for small objects [YOLO26]. It is the spec's named choice (§5.2). **It is only usable if the whole app is released under AGPL-3.0** (Q1). |
| **Own CenterNet-style heatmap net** (recommended) | Our code, any license | PyTorch → `coremltools` `ct.convert` → `.mlpackage`, fixed shapes, FP16 + 8-bit palettization [CT-OPT] | Balls are near-identical circles of known size on a rectified table crop. A heatmap peak plus a sub-pixel offset plus a 17-way class head is a small, well-understood problem. No license risk. |
| YOLOX-nano/tiny | Apache-2.0 (per Roboflow and community model cards, unverified upstream) [YOLOX-RF], [YOLOX-HF] | PyTorch → coremltools. A community Core AI build reports about 22 ms for YOLOX-S at 640 on an iPhone 17 Pro [YOLOX-HF] | Proven anchor-free detector. Good fallback. |
| MIT-YOLOv9 (MultimediaTechLab) | MIT; the original YOLOv9 repo is GPL-3.0 [MIT-YOLO] | PyTorch → coremltools | Fallback. Weights must come from the MIT repo, not from GPL sources. |
| RF-DETR Nano–Large | Apache-2.0. Atto/Femto/Pico/XL/2XL are under PML 1.0 [RF-DETR], [RF-DETR-LIC] | ONNX/TFLite documented. Core ML is not documented, so conversion is unverified. | Transformer. Small balls plus ANE op support are a risk. Not first choice. |
| D-FINE | Apache-2.0 (secondary source) [DFINE-RF] | Not verified | Not first choice. |
| Create ML Object Detector | We own the trained model | Built in. "Full network" is YOLOv2-based; transfer learning is about 5× smaller with ≥80 examples per class [CREATEML] | Fastest **spike/baseline**. Probably weak on small balls. |

**Recommendation.** Phase 3 starts with a 1-day Create ML baseline and a classical cloth-segmentation baseline, used as auto-labellers and comparators. In parallel, build the own heatmap net as the shipping detector. Benchmark YOLO26n in `tools/` *for comparison only, never shipped* unless Q1 resolves to AGPL.

### 4.3 Rectified-crop trick

After calibration, warp the table ROI to a canonical top-down image through `H_R`, for example 1024×512 for any table size, at about 1 ms on the GPU (est.). Every ball is then a near-constant ~23 px circle (est.: 1024 px / 2.54 m × 57 mm). This shrinks the detector's scale range and keeps the input tensor fixed for the ANE. It also gives synthetic and real data the same geometry. The cost is that far-rail balls are upsampled from fewer source pixels, so the limb fit for metric work uses the original frame.

### 4.4 Identity: cue, 1–15, solid vs stripe

Three layers:
1. **Detector class head** (17 logits: cue, 1–15, unknown ball). Cheap, but noisy.
2. **Crop classifier** at 10 Hz and on uncertain tracks only. A 48×48 crop from the full-resolution frame goes to a tiny CNN (≤0.5 M params). It also gets the hand-crafted features from the spec: a hue histogram in a white-balanced space, a **stripe white-ratio** (the fraction of near-white pixels outside the specular highlight), and a number-circle presence score.
3. **Temporal and global inference in CueCore.** Each track carries a 16-way posterior that is updated by Bayes with a confusion-matrix likelihood. A Hungarian assignment across all tracks then enforces that **each ID exists at most once**, that pocketed balls are gone, and the game-state priors (the 9-ball rack holds 1–9, the cue ball is the white with no number).

Known confusions to target with synthetic hard cases: 1/9 (yellow), 3/7/5 (red/maroon/orange) and 11/15/13 (their stripe twins), 2/4 (blue/purple under warm light), and **stripe balls showing an almost solid face** when the band faces the camera. That last case is why temporal smoothing and mesh multi-view fusion matter. Per-table colour calibration happens at calibration: cloth white point, lamp colour temperature, and a reference from the cue ball.

### 4.5 Cue stick and stroke (detection only)

`VNDetectHumanBodyPoseRequest` at 10–15 Hz before the shot finds the shooter's wrists and elbows. A cue-line fit (an edge or line segment along the forearm direction, ending near the cue ball) gives the live aim direction. A stroke-start cue is the line's tip approaching the cue ball, then the cue ball's velocity jumping. Line detection belongs with the overlay; identity (§5.8) consumes the pose.

## 5. Tracking and shot segmentation

### 5.1 Tracker (CueCore, table frame)

- **State per track:** position, velocity, motion mode {rest, moving}, an ID posterior, and a missed-frame count.
- **Model:** a constant-velocity Kalman filter with a rolling-deceleration prior. **Cushion reflection is handled in the predict step.** When the prediction crosses a nose line at R from the cushion, reflect the normal component using e_c = 0.85 (the same as Physics, D16). Process noise inflates after any collision.
- **Association:** gated Mahalanobis distance plus the ID posterior as a soft cost, solved with the Hungarian method. Ball–ball collisions are expected exactly where two tracks meet, so the gate widens there and both tracks' velocities are re-initialised.
- **Physics-aided prediction for fast shots:** for the break and power shots, seed predictions from `Simulator` using the observed cue-ball launch. The detector's job becomes confirming rather than finding. This is what keeps the tracker usable at 2–4 ball diameters per frame.
- **Occlusion:** a player's body hides balls. Tracks coast while they are in an occluded region (the body-pose bounding box projected to the table). A track that disappears while occluded is never declared pocketed unless it is inside a pocket capture zone.

### 5.2 Segmenter state machine

`idle (all rest)` → `armed` (stroke cue, or a person within reach of the cue ball) → `moving` (cue-ball speed above 0.10 m/s for ≥2 frames; that crossing time is the shot start) → `settling` → `rest` (all speeds below 5 mm/s for N = 30 frames, 0.5 s, which is the shot end) → emit `ShotOutcome` plus the track log (clip timestamps for Highlights). All thresholds are parameters, tuned in replay.

### 5.3 Building `ShotOutcome` from tracks (INTERFACES Rules)

| Field | Inference from tracks | Difficulty |
|---|---|---|
| `firstContact` | The first object-ball track whose speed rises while within 2R + ε of the cue-ball track. A physics replay of the observed launch breaks ties. | Medium. A thin cut at speed is the hard case. |
| `pocketed` | The track ends inside a pocket capture zone (H_cloth) and does not reappear. | Easy |
| `offTable` | The track leaves the playing surface outside any pocket zone, or ends outside the rail polygon. | Medium (rare, and occlusion confuses it) |
| `anyRailAfterContact` | A track's normal velocity flips sign within R + ε of a nose line after first contact. A pocketed ball also satisfies "something pocketed". | Medium |
| `objectBallsToRailOnBreak` | Count distinct object balls that touch a rail during the break. | **Hard at 60 fps.** Balls move fast in a crowded cluster. (R3) |
| `calledPocket` | Not perception. Comes from the aim line at stroke start (§3 spec). | n/a |

Uncertain outcomes (confidence below a threshold) should not be guessed. They go to a post-shot visual confirmation (Q2).

## 6. Performance budget (A17 Pro, 60 fps frame = 16.7 ms)

All numbers are est. targets, to be measured with `os_signpost` and the Xcode Core ML performance report on the 15 Pro Max. Units run concurrently: ANE, GPU and CPU are separate queues.

| Stage | Rate | Unit | Budget |
|---|---|---|---|
| Capture + Metal texture | 60 Hz | ISP | 0 CPU |
| Rectify table ROI to 1024×512 | 30 Hz | GPU | ≤ 1.5 ms |
| Ball detector (own net or YOLO-n class, 8-bit) | 30 Hz | ANE | ≤ 8 ms. The 3.7 ms YOLO26n@640 on a 17 Pro [UL-COREML] scaled for 1.3× pixels and an older ANE gives about 6–9 ms. |
| Predicted-window refinement on in-between frames (sub-pixel peak or limb fit) | 60 Hz | GPU | ≤ 1.5 ms |
| Identity crop classifier (batch ≤ 16 × 48²) | 10 Hz + on demand | ANE | ≤ 2 ms |
| Tracker + assignment + ID filter (CueCore) | 60 Hz | CPU | ≤ 0.5 ms |
| Segmenter | 60 Hz | CPU | ≤ 0.1 ms |
| Body pose + cue line (pre-shot only) | 10–15 Hz | ANE/CPU | ≤ 10 ms |
| Calibration validation edge pass | ≤ 1 Hz | GPU | ≤ 2 ms |
| Overlay render (Overlay track) | 60 Hz | GPU | ≤ 3 ms |
| **Glass-to-overlay latency** | | | **≤ 50 ms** p95 (about 2 frames of capture pipeline plus processing) |
| Model sizes | | disk | detector ≤ 4 MB, classifier ≤ 1 MB (palettized) |

Compute units default to `.cpuAndNeuralEngine`, which keeps the GPU free for camera preview and overlay [UL-COREML]. Check the ANE op coverage of every model. Unsupported ops silently fall back to CPU [CML-BENCH]. Thermal: watch `ProcessInfo.thermalState`. On `.serious`, drop the detector to 20 Hz and the classifier to 5 Hz before the overlay frame rate drops (Phase 9: never below 24 fps).

**Core AI (iOS 27).** Reports say WWDC 2026 introduced Core AI as Core ML's successor, and that `.mlpackage` still runs [COREAI-1], [COREAI-2]. These are news sources, not Apple documentation (unverified). Keep the model runtime behind the `BallDetector` protocol so that switching runtimes is a one-file change.

## 7. Datasets

**Rule (D5):** no third-party images or footage are committed. `tools/perception_data/manifest.json` records each set's URL, version, license, attribution text and class map. A download script runs on the Mac at dev time. Data lands in a git-ignored directory. If shipped weights were trained on CC BY data, the app's acknowledgements carry the attribution.

| Dataset | Content | License (as listed) | Redistribute in public repo? | Status |
|---|---|---|---|---|
| Roboflow "Pool Ball Detection" (main-cpmku) | 16 classes (cue, 1–15) | CC BY 4.0 [RF-SEARCH] | License allows it with attribution. **We still do not commit it** (uploader-claimed license, images of unknown provenance). | The page returned 403 to my fetcher. Confirm manually. |
| Roboflow "Pool Balls" (bastogne-billiards) | 16 classes by name | CC BY 4.0 [RF-SEARCH] | Same | Confirm manually |
| Roboflow "Pool Balls" (pool-tracking) | cue + 1–9 | CC BY 4.0 [RF-SEARCH] | Same | Confirm manually |
| Roboflow "Pool Balls" (ben-gann) | 22 classes incl. 00Ball–15Ball | CC BY 4.0 [RF-SEARCH] | Same | Confirm manually |
| Roboflow "billiards ball detection" (cuebit) | ball, table, cue | CC BY 4.0 [RF-SEARCH] | Same | Useful for the cue class |
| Roboflow "8 ball pool" (skylep), "Billiard Balls" (adam-shortland) | balls | CC BY 4.0 [RF-SEARCH2] | Same | Confirm manually |
| Roboflow "Detect ball on pool table" (cueball), "Pool ball detection" (nadnq) | Unclear classes, no description | CC BY 4.0 [RF-SEARCH] | Same | Low value |
| **pix2pockets** (DTU, "8-Ball Pool" bachelorthesis/l530o) | 195 in-the-wild images, 5,748 masks of balls and **table dots** | **Not stated** on the l530o page or the project page. The related "8-Ball Pool Segmentation" set lists CC BY 4.0 [PIX2P-RF] | **Unknown, so do not use for shipped weights** until the license is confirmed | Best real benchmark for calibration (dots) |
| Roboflow "Nine-balls-segmentation" (billiards-project) | 9-ball segmentation | Not checked | Unknown | To check |
| Kaggle | No pool-ball set found in search | n/a | n/a | Not found |
| **Our synthetic set** (§8) | Unlimited, every label exact | **Ours** (Blender output belongs to the creator [BLENDER-LIC]) | **Yes.** Commit a small golden subset for tests. | Proposed |
| **Our in-app data collection** (SPEC §12, opt-in) | Real frames from the user's table, auto-proposed labels | Ours, but personal | **No** (D5: no personal footage). It stays on the Mac and is never committed. | Proposed (Q5) |

## 8. Synthetic data: the license-safe path

**Generator:** `tools/perception_synth/` drives headless Blender (`blender -b -P render.py`). Blender is GPL, but "what you create with Blender is your sole property" [BLENDER-LIC]. The pipeline is our own Python. BlenderProc is GPL-3.0 [BLENDERPROC] and is only a convenience. Running it does not make our renders GPL, but keeping our own small script avoids the question. pooltool (Apache-2.0 [POOLTOOL]) also has a 3D renderer and is an alternative.

**Scenes from our physics.** The virtual table and `Simulator` export `TableState` JSON for (a) racks and broken layouts, (b) mid-shot frames with per-ball velocity and spin, and (c) full shot sequences rendered as 60 fps clips. Those clips give **synthetic replay videos with exact ground-truth `ShotOutcome`**, which can be committed.

**Domain randomisation:** cloth colour (green, blue, red, grey, tan) and texture wear; our own painted ball textures in the standard colour code, with no brand logos; lamp type, count, height and colour temperature (2700–6500 K); specular glare; camera poses sampled from the tripod envelope (height 1.0–2.2 m, all four sides and corners, ±15° roll) plus handheld jitter; iPhone-like lens distortion, noise, JPEG/HEVC artifacts; **motion blur from velocity × exposure**; occluders (procedural mannequins, cues, hands, chalk, drinks on the rail); balls frozen in a pocket jaw or touching each other; stripe-band orientation spread uniformly.

**Labels for free:** 2D centre (projected exactly), radius, ID, visibility fraction, ball-plane table coordinates, pocket and diamond keypoints, cloth mask, `K`, pose, `H_R`.

**Volume (est.):** 50–100 k stills at 1024×512 rectified plus raw camera views, using Cycles with the Metal GPU on Apple Silicon at about 1–3 s per image, which is 1–3 days unattended. EEVEE is about 10× faster for bulk data. Use Cycles for a hard-case subset. **Mix:** pretrain on synthetic, fine-tune on licensed real data plus local opt-in captures. Always report held-out **real** metrics, because synthetic metrics alone do not count toward the Phase 3 gate.

## 9. Training pipeline on the Mac and targets

1. `tools/perception_train/` uses `uv` (like `physics_fixtures`), PyTorch on MPS, and the own heatmap net (or YOLOX/MIT-YOLO as fallback).
2. Export with `coremltools` `ct.convert` (from `torch.export` or a trace). Use fixed input shapes and FP16, then post-training 8-bit palettization (4-bit grouped-channel only if accuracy holds) [CT-OPT]. Avoid ANE-hostile ops: dynamic shapes, TopK, Scatter, GatherND (community guidance, unverified) [CT-COMM].
3. Validate in Python with `CPU_AND_NE` [UL-COREML], then with the Xcode Core ML performance report on the device. Golden-output parity: the `.mlpackage` and PyTorch agree within 1e-2 on 50 fixed inputs.
4. Version models with a hash in `Resources/Models/`, plus a JSON model card covering data mix, licenses, metrics and the date.
5. Create ML is the 1-day baseline (§4.2).

| Metric | Target | Phase 3 gate link |
|---|---|---|
| Detector recall / precision, visible balls at rest | ≥ 99.5% / ≥ 99.5% | supports identity ≥95% |
| Centre error at rest (table frame) | ≤ 3 mm median, ≤ 6 mm p95 (pix2pockets reports 0.4 cm single-image [PIX2P]) | overlay accuracy (Phase 4) |
| Centre error moving (≤ 3 m/s) | ≤ 15 mm p95 | |
| Identity per crop / per track (smoothed + uniqueness) | ≥ 90% / **≥ 98%** | gate is ≥ 95% |
| Table size class | 100% on test tables. Length error ≤ 1.5%. | D12 |
| Calibration pocket reprojection | ≤ 2 px RMS | |
| Shot start / end | ±1 frame / ±5 frames | "correct in replays" |
| firstContact, pocketed, rail-after-contact | ≥ 97%, ≥ 99%, ≥ 97% | rules correctness |
| Detector + classifier size | ≤ 4 MB + ≤ 1 MB | |
| Throughput | Detector ≥ 30 Hz, tracker 60 Hz, sustained 1 h without dropping below 24 fps | gate + Phase 9 |

## 10. TDD and QA plan

### 10.1 CueCore (`swift test`, pure Swift, written first)

| Unit | Red tests (examples) |
|---|---|
| `Homography` (DLT with normalisation, apply, invert, compose) | Round-trip on random projective cameras. Degenerate (collinear) input is rejected. Noise robustness. |
| `CameraModel` / `BallPlaneHomography` | `H_R` maps a table point at z = R to the same pixel as `K[R|t]` applied to the 3D point. z = 0 reduces to `H_cloth`. |
| `SphereProjectionBias` | Analytic ellipse centre vs projected centre on synthetic spheres. Zero on the optical axis. |
| `TableSizeEstimator` (fuse + snap) | Noisy estimates around 80/92/100 in snap correctly. 76/78/88 in becomes custom. An outlier source is down-weighted. A W/L ratio check failure is flagged. |
| `CalibrationHealth` | A drift injection (rotation 0.5°) goes to stale within 2 s. Noise alone stays healthy. |
| `BallTracker` | **Fixtures = `Simulator` traces sampled at 60 Hz, plus Gaussian noise (σ = 3 mm), 5% dropouts, occlusion windows, and swapped detections.** The tracker recovers trajectories within tolerance and keeps IDs through collisions and cushion hits. |
| `IdentityFilter` | Confusion-matrix noise converges to the true IDs. The uniqueness constraint resolves 1/9 swaps. A pocketed ball is never re-assigned. |
| `ShotSegmenter` + `OutcomeBuilder` | For 500 random simulated shots, the `ShotOutcome` built from noisy tracks equals the one built from the true `ShotTrace` (≥ 97% per field, 100% on simple shots). Low confidence is flagged, never guessed. |

### 10.2 App target (XCTest on the `CueCoach iPhone 15 Pro` simulator)
- Colour and stripe features on committed synthetic crops.
- Model I/O contract: shapes, class count, and output decoding on golden synthetic frames (committed, ours).
- `FrameSource` replay determinism: the same `.mov` produces the same detection hash.
- The simulator has no camera or LiDAR, and Core ML runs off the ANE there. It is for function only, never for performance.

### 10.3 Replay QA (SPEC §12 Replay mode)
- **Clip sets:** (a) committed **synthetic** clips rendered from physics traces, with exact ground truth; (b) **real** clips recorded on the test tables, stored outside git (D5), each with a `*.truth.json` sidecar (table size, shot start/end frames, firstContact, rails, pocketed, final positions for a subset). Labels are made with a DevTools label tool: run the pipeline, then a human corrects it.
- **Harness:** decode every frame with original timestamps and run the full pipeline, using deterministic mode and also a real-time mode that drops frames under simulated load. It emits a metrics JSON (§9 table), and a regression script fails on any metric falling below its threshold.
- **Coverage matrix:** 7/8/9 ft × cloth colours × 4 camera positions × lighting × {break, soft cut, power shot, bank, scratch, ball off table, occluded shot}.

### 10.4 Device QA (D6)
- 15 Pro Max: `os_signpost` stage timings, the Core ML performance report (ANE residency), a 1-hour thermal soak logging fps and thermal state, and calibration on at least 3 real tables (including The Rive, D7).
- 17 Pro Max: second view for mesh fusion (Phase 5). The same perception binary must hit the same metrics.

## 11. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | **AGPL** if Ultralytics weights ship in a non-AGPL repo | Legal and licensing | Own net or Apache/MIT fallback. Ultralytics stays benchmark-only (Q1). |
| R2 | Synthetic-to-real gap | Accuracy | Heavy randomisation, real fine-tune, gate on real held-out metrics only |
| R3 | Break tracking at 60 fps (balls move 2–4 D per frame, clustered) | Break fouls and `objectBallsToRailOnBreak` | Physics-seeded prediction, short exposure, mesh second view, 120 fps option (Q3), confirm when uncertain (Q2) |
| R4 | LiDAR depth/video sync drops [FORUM-SYNC]; ARKit format limits | Calibration | LiDAR only during the short scan. Ball-size and ARKit estimators are independent fallbacks. |
| R5 | Stripe balls showing a solid face; warm light shifting hues | Identity | Temporal posterior, uniqueness assignment, white balance locked at calibration, multi-view |
| R6 | Occlusion by players | Missed pockets or first contact | Occlusion-aware coasting, never infer a pocket from disappearance alone, mesh fusion |
| R7 | Tripod bump or slow drift | All geometry | CoreMotion trigger, rail-line residual monitor, silent re-fit |
| R8 | ANE op fallback to CPU | Latency, thermal | Fixed shapes, the performance report in CI-style device runs, a simple architecture |
| R9 | Roboflow licenses are uploader claims; pix2pockets license unknown | Data provenance | Manifest only, nothing committed, attribution, exclude unknown-license sets from shipped weights |
| R10 | Core ML vs Core AI transition on iOS 27 | API churn | Runtime behind `BallDetector`. Verify against Apple docs before Phase 3. |
| R11 | 7 ft size variance; `TableSize.sevenFoot` hard-coded at 80 × 40 | Physics and rules geometry | Measured custom size allowed (D12). `TableSpec` takes arbitrary dimensions. |

## 12. Proposed interface additions (for the head orchestrator, not applied)

```swift
// CueCore (pure Swift, testable)
public struct Homography { var m: simd_double3x3; func apply(_ p: Vec2) -> Vec2; var inverse: Homography
                           static func dlt(_ src: [Vec2], _ dst: [Vec2]) -> Homography? }
public struct CameraModel { var K: simd_double3x3; var R: simd_double3x3; var t: SIMD3<Double>
                            func planeHomography(z: Double) -> Homography }      // z = 0 cloth, z = R balls
public struct TableCalibration: Codable, Sendable { var camera: CameraModel; var spec: TableSpec   // measured
                            var quality: CalibrationQuality; var timestamp: Double }
public enum TableSizeEstimator { static func fuse(_ e: [SizeEstimate]) -> (TableSpec, snapped: TableSize?) }
public struct BallObservation: Sendable { var t: Double; var table: Vec2; var sigma: Double
                            var classLogits: [Float]; var confidence: Float; var sourcePeer: Int }
public struct BallTracker { mutating func update(_ obs: [BallObservation], at t: Double) -> [Track] }
public struct ShotSegmenter { mutating func ingest(_ tracks: [Track], at t: Double) -> SegmenterEvent? }
                            // .started(t), .ended(ShotOutcome, TrackLog, confidence: [Field: Double])
// App
protocol FrameSource: AsyncSequence where Element == CameraFrame   // camera | replay .mov
struct CameraFrame { var pixelBuffer; var time: Double; var intrinsics: simd_float3x3?; var depth: AVDepthData? }
protocol TableCalibrator { func calibrate(_ s: FrameSource, taps: [CGPoint]?) async throws -> TableCalibration
                           func health(_ f: CameraFrame) -> CalibrationHealth }   // .ok/.suspect/.stale
protocol BallDetector { func detect(_ f: CameraFrame, _ c: TableCalibration) async -> [BallObservation] }
```

`BallObservation` is also what peers stream over the mesh (SPEC §5.7: table-coordinate detections, not video), so it should be `Codable`.

**Cross-track note (Geometry).** `Table.swift` places `footSpot` at 0.75 L and `headStringX` at 0.25 L. INTERFACES puts the origin at the foot cushion with +x toward the head, which would put the foot spot at 0.25 L and the head string at 0.75 L. One of the two is inverted. Perception maps detections into this frame, so it should be settled before Phase 3.

## 13. Open questions for the user (product ambiguity: stop and ask)

- **Q1 License.** SPEC §5.2 names Ultralytics YOLO, which is AGPL-3.0 including trained weights. Options: (a) release the whole CueCoach repo under AGPL-3.0 and use YOLO26; (b) use a permissive repo license and our own or Apache/MIT detector (**recommended**); (c) buy an Ultralytics Enterprise license.
- **Q2 Uncertain fouls.** When tracking cannot tell (occlusion, a thin hit), should the app show a post-shot visual confirm (ball icons, one tap on any phone), or fall back silently to "no foul"?
- **Q3 Frame rate.** 60 fps (cooler, higher resolution) or 120 fps slo-mo format for the whole session (better breaks, more heat)? The recommendation is 60 fps by default, with 120 fps tested in the Phase 3 spike.
- **Q4 7 ft tables.** Bar boxes vary (76/78/80 in). Should we use the measured size as-is (recommended), or always snap to one 7 ft preset?
- **Q5 Real training frames.** Can opt-in data-collection frames be AirDropped to the Mac for fine-tuning? They would never be committed.

---

## Sources

| Key | Source | URL |
|---|---|---|
| WPA-EQ | WPA Tournament Table & Equipment Specifications (poolroom.com mirror) | https://www.poolroom.com/tournament-table-equipment-specifications/ |
| AZ-BAR | AZBilliards forum, "What does bar box mean?" (7 ft 40×80, 88×44) | https://forums.azbilliards.com/goto/post?id=6831648 |
| WIKI-TABLE | Wikipedia, Billiard table (7 ft 76×38 cited in search summary) | https://en.wikipedia.org/wiki/Pool_table |
| DD-SPEED | Dr. Dave, "How fast does the CB travel for a range of shots?" | https://drdavepoolinfo.com/?p=2486 |
| DD-BREAK | Dr. Dave, Billiards Digest Jan 2017 (break speed) | https://billiards.colostate.edu/bd_articles/2017/jan17.pdf |
| A17 | Wikipedia, Apple A17 Pro (35 TOPS, cites Apple newsroom 2023-09-12) | https://en.wikipedia.org/wiki/Apple_A17_Pro ; https://web.archive.org/web/20230912221839/https://www.apple.com/newsroom/2023/09/apple-unveils-iphone-15-pro-and-iphone-15-pro-max/ |
| SPECS15 | Apple, iPhone 15 Pro Technical Specifications | https://support.apple.com/en-us/111829 |
| WWDC22-LIDAR | WWDC22 110429, "Discover advancements in iOS camera capture" | https://developer.apple.com/videos/play/wwdc2022-110429 |
| AV-LIDAR | Apple, Capturing depth using the LiDAR camera | https://developer.apple.com/documentation/avfoundation/capturing-depth-using-the-lidar-camera |
| AV-LIDAR-DOC | Apple, `builtInLiDARDepthCamera` | https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtinlidardepthcamera |
| FORUM-SYNC | Apple Dev Forums 742501, synced depth/video not received | https://developer.apple.com/forums/thread/742501 |
| ARKIT-DEPTH | Apple, `ARDepthData` (confidenceMap) | https://developer.apple.com/documentation/arkit/ardepthdata |
| ARKIT-FS | Apple, `supportsFrameSemantics(_:)` | https://developer.apple.com/documentation/arkit/arconfiguration/supportsframesemantics(_:) |
| MED-5M | Medium, "ARKit 911 — Scene Reconstruction with a LiDAR Scanner" (5 m, secondary) | https://medium.com/@arkit/arkit-911-scene-reconstruction-with-a-lidar-scanner-57ff0a8b247e |
| VN-TRAJ | Apple, Identifying trajectories in video | https://developer.apple.com/documentation/vision/identifying-trajectories-in-video |
| VN-TRAJ2 | Apple, Detecting moving objects in a video | https://developer.apple.com/documentation/vision/detecting-moving-objects-in-a-video |
| PIX2P | pix2pockets project page / arXiv 2504.12045 | https://pix2pockets.compute.dtu.dk/ ; https://arxiv.org/abs/2504.12045 |
| PIX2P-RF | Roboflow, bachelorthesis "8-Ball Pool" / "8-Ball Pool Segmentation" | https://universe.roboflow.com/bachelorthesis/8-ball-pool-l530o ; https://universe.roboflow.com/bachelorthesis/8-ball-pool-segmentation |
| UL-FORUM | Ultralytics community, "YOLOv11 AGPL License for On-Premises Use" | https://community.ultralytics.com/t/yolov11-agpl-license-for-on-premises-use/1529 |
| UL-IOS | Ultralytics yolo-ios-app | https://github.com/ultralytics/yolo-ios-app |
| UL-COREML | Ultralytics docs, CoreML integration (export args, iPhone 17 Pro / iOS 27.0.1 latencies) | https://docs.ultralytics.com/integrations/coreml/ |
| YOLO26 | "Ultralytics YOLO26: Unified Real-Time End-to-End Vision Models" (summary); Roboflow YOLO26 page | https://www.opentrain.ai/papers/ultralytics-yolo26-unified-real-time-end-to-end-vision-models--arxiv-2606.03748/ ; https://inference-models.roboflow.com/models/yolo26-object-detection/ |
| RF-LIC | Roboflow model licenses (YOLOE / YOLO AGPL listing) | https://roboflow.com/model-licenses/yoloe |
| RF-DETR | Roboflow, "RF-DETR is free to use commercially (Apache 2.0)"; RF-DETR docs | https://blog.roboflow.com/rf-detr-is-free-to-use-commercially/ ; https://rfdetr.roboflow.com/latest/ |
| RF-DETR-LIC | Roboflow, RF-DETR model licensing (PML 1.0 sizes) | https://roboflow.com/model-licenses/rf-detr |
| YOLOX-RF | Roboflow playground, YOLOX (Apache 2.0) | https://playground.roboflow.com/models/megvii/yolox |
| YOLOX-HF | Hugging Face, YOLOX-S Core AI (iPhone 17 Pro ~22 ms) | https://huggingface.co/coreai-community/YOLOX-CoreAI |
| MIT-YOLO | MultimediaTechLab/YOLO (MIT) via awesome.ecosyste.ms; LibreYOLO card | https://awesome.ecosyste.ms/projects/github.com%2FMultimediaTechLab%2FYOLO ; https://huggingface.co/LibreYOLO/LibreYOLO9E2Et |
| DFINE-RF | Roboflow playground, D-FINE vs YOLOv9 | https://playground.roboflow.com/models/compare/d-fine-vs-yolov9 |
| CREATEML | Apple Tech Talk 10155 (Create ML object detection: full network vs transfer learning) | https://developer.apple.com/videos/play/tech-talks/10155/ |
| CT-OPT | coremltools, Optimization What's New / Workflow | https://apple.github.io/coremltools/docs-guides/source/opt-whats-new.html ; https://apple.github.io/coremltools/docs-guides/source/opt-workflow.html |
| CT-COMM | Community coreml-optimizer skill guide (ANE-blocking ops, unverified) | https://smithery.ai/skills/ckorhonen/coreml-optimizer |
| CML-BENCH | Photoroom Core ML benchmark 2023; 3Nsofts Core ML benchmarks 2026 | https://www.photoroom.com/inside-photoroom/core-ml-performance-benchmark-2023-edition ; https://3nsofts-site.pages.dev/insights/core-ml-inference-performance-benchmarks-2026 |
| COREAI-1 | 9to5Mac, Apple replacing Core ML with Core AI for iOS 27 | https://9to5mac.com/2026/03/01/apple-replacing-core-ml-with-modernized-core-ai-framework-for-ios-27-at-wwdc/ |
| COREAI-2 | ecorpit, "iOS 27 Core AI: 5 changes"; ai2.work Core AI | https://ecorpit.com/core-ai-framework-ios-27-replaces-core-ml/ ; https://ai2.work/blog/apple-core-ai-lets-apps-run-qwen-and-sam3-fully-on-device |
| RF-SEARCH | Roboflow Universe pool datasets (CC BY 4.0 per listing) | https://universe.roboflow.com/main-cpmku/pool-ball-detection-jhi6w ; https://universe.roboflow.com/bastogne-billiards/pool-balls-uibmm ; https://universe.roboflow.com/pool-tracking/pool-balls-rpx9d ; https://universe.roboflow.com/ben-gann-lscqy/pool-balls-qlnkb ; https://universe.roboflow.com/cuebit/billiards-ball-detection-lmzkl ; https://universe.roboflow.com/cueball/detect-ball-on-pool-table ; https://universe.roboflow.com/pool-ball-detection-nadnq/pool-ball-detection-lm32j |
| RF-SEARCH2 | Roboflow Universe (skylep, adam-shortland, billiards-project) | https://universe.roboflow.com/skylep/8-ball-pool-mxyjm ; https://universe.roboflow.com/adam-shortland-wsc62/billiard-balls-yudfl ; https://universe.roboflow.com/billiards-project/nine-balls-segmentation-9a82w |
| BLENDER-LIC | Blender license page ("What you create with Blender is your sole property") | https://www.blender.org/about/license/ |
| BLENDERPROC | DLR-RM/BlenderProc LICENSE (GPL-3.0) | https://github.com/DLR-RM/BlenderProc/blob/main/LICENSE |
| POOLTOOL | ekiefl/pooltool (Apache-2.0); JOSS paper | https://github.com/ekiefl/pooltool ; https://theoj.org/joss-papers/joss.07301/10.21105.joss.07301.pdf |
| PRIOR-ART | thkodin/pool-ball-tracking (YOLO + homography + KCF); Roboflow pool analytics blog | https://github.com/thkodin/pool-ball-tracking ; https://blog.roboflow.com/pool-table-analytics-object-detection/ |
