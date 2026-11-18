# Perception research: camera to table + balls (SPEC §5.1–5.3, D12)

Compiled 2026-11-06, revised the same day after a critical review (see **Reviewer notes** at the end). This is research and a design proposal. It contains no code. Every external claim cites a key from **Sources**. "Est." marks numbers I derived (scripts and formulas shown inline); they still need measuring on the 15 Pro Max (D6 perf gate). "Unverified" marks claims I could not confirm against a primary source.

**TL;DR**
1. **Placement decides accuracy.** One phone on the 24 mm wide lens can frame a 9 ft table from a long side, but far-rail balls are only ~17–22 px at 1080p and each pixel is 5–15 mm of table depth (§2.2). Recommended: a long side, camera ≥ 2.2 m off the floor. Calibrate shows a visual "raise / move back" cue.
2. **Camera model = pinhole + measured lens distortion, everything locked.** Stabilization explicitly off, focus/exposure/WB locked after calibration, GDC off with Apple's distortion lookup table, per-frame `K` from the tracking stream. The pose is solved in the tracking images; only the metric table size carries over from the ARKit/LiDAR scan (§3).
3. **Head vs foot end** is resolved from the rack and break positions, with a one-tap visual fallback. Mesh peers align to the host's frame by matching rest positions (§3.5).
4. **Table size (D12):** depth (LiDAR+ARKit, one correlated source), ball size (systematic term, no cue ball), and rack spacing. Classify into {bar box, 8 ft, 9 ft}, which separate cleanly. Inside a class, use the measured length, because 76/78/80 in and 88/90/92 in can't be told apart at a realistic σ (§3.4).
5. **Detect in the (undistorted) camera image, not a rectified crop.** Sphere-bias correction, then map through the ball-plane homography `H_R` (§4.3).
6. **Segmenter thresholds come from the noise model** (window fits, hysteresis, armed gating), with states for ball-in-hand, spotting, re-rack, hand-moved balls and the WPA 5 s pocket rule (§5).
7. **Detector license is a user decision (Q1), presented neutrally.** The repo has no LICENSE yet and nothing is store-distributed, so AGPL + YOLO26 is cheap. The custom net costs weeks and carries accuracy risk (§4.2).
8. **Runtime:** Core ML `MLModel` is not deprecated on iOS 27. Core AI (iOS 27+, `.aimodel`) is new. Keep the runtime behind `BallDetector` (§6.3).

---

## 1. Constraints that shape the design

| Constraint | Consequence for perception |
|---|---|
| Zero network calls (SPEC §2) | Models are bundled. All training happens on the Mac. Dataset downloads are dev-time only, in `tools/`. |
| Free Personal Team | Camera, ARKit, LiDAR depth, CoreMotion, Core ML and Vision need only `Info.plist` usage strings. None needs a restricted entitlement. |
| iPhone 15 Pro / Pro Max, A17 Pro | 6-core CPU (2P+4E) and a 35 TOPS Neural Engine [A17]. Capture: 4K at 24–60 fps, 1080p at 25–60 fps, slo-mo 1080p at 120/240 fps. Main lens 24 mm f/1.78 with sensor-shift OIS, ultra-wide 13 mm at 120°, LiDAR [SPECS15]. |
| No text/audio while aiming | Calibration prompts, orientation choice and push-out declaration are icons only. |
| Phase 3 gate | ≥ 30 fps on the 15 Pro, ball identity ≥ 95% on held-out video, shot start/end correct in replays. |
| Public repo, no footage (D5) | Real test video lives outside git. Only synthetic renders and manifests are committed. |
| Physics ships in CueCore (D8) | `Simulator` traces are smoke-test ground truth. Robustness is tested with *mismatched* physics (§10.1). |

## 2. Table geometry and camera placement

### 2.1 Table facts

| Item | Value | Source |
|---|---|---|
| Ball diameter | 2¼ in (+0.005 in) = 57.15 mm | [WPA-EQ] |
| 9 ft playing surface (nose to nose) | 100 × 50 in | [WPA-EQ] |
| 8 ft playing surface | 92 × 46 in (WPA). Also sold: 88 × 44 in (Valley 101") and 90 × 45 in (Diamond Pro-Am 8') | [WPA-EQ], [VALLEY], [DIAMOND] |
| 7 ft (bar box) | **Not in the WPA spec** (WPA lists 9 ft and 8 ft only). Sold: 76 × 38 in (Brunswick 7'), 80 × 40 in (Valley 93"). 78 × 39 in appears in an Olhausen sheet I could not fetch (403), so it is **unverified** | [WPA-EQ], [BRUNSWICK], [VALLEY], [OLHAUSEN] |
| Cushion nose height | 62.5–64.5% of ball diameter ≈ 35.7–36.9 mm | [WPA-EQ] |
| Corner / side pocket mouth | 4.5–4.625 in / 5–5.125 in | [WPA-EQ] |
| Bar-box cue balls | Oversized 2⅜ in (60.3 mm, +5.5%) or standard-size magnetic | [CB-OVER], [CB-HSW] |
| Ball speeds | Slow ≈ 3 mph, medium ≈ 7, fast ≈ 12, power ≈ 20. A pro break is 25–30 mph (11–13 m/s) | [DD-SPEED], [DD-BREAK] |

Consequences:
- **Rail lines are raised.** Cushion noses sit at ≈ 1.27 R, close to the ball-centre plane (1.0 R). They are modelled at their true height, otherwise the homography picks up a ~36 mm parallax error.
- **Per-frame motion at 60 fps:** 1.3 m/s moves 2.2 cm (0.4 D). 5.4 m/s moves 9 cm (1.6 D). A 13 m/s break moves 22 cm (3.8 D). At 30 Hz these double, so a break moves up to ~44 cm between detections.

### 2.2 Field of view and placement (est.)

Script: pinhole camera aimed at the table centre, rails modelled 15 cm wide, the whole table plus rails inside 95% of a 16:9 frame, cloth 0.76 m above the floor. Lens FOV from the 35 mm-equivalent focal length (diagonal). "Setback" is the smallest distance from the outer rail that fits. "Depth mm/px" is the table-plane error per pixel along the viewing direction at the worst far corner, `d / (f · sin elevation)`.

| Table | Lens | Position | Camera height (floor) | Setback | Far-ball size @1080p | Far elevation | Rectified elongation (1/sin) | Depth mm/px @1080p |
|---|---|---|---|---|---|---|---|---|
| 9 ft | wide 24 mm | long side | 1.5 m | 2.0 m | 21 px | 11° | 5.2× | 14 |
| 9 ft | wide 24 mm | long side | **2.2 m** | 1.6 m | 22 px | 24° | 2.5× | **6.6** |
| 9 ft | wide 24 mm | long side | 2.6 m | 1.2 m | 22 px | 32° | 1.9× | 4.8 |
| 9 ft | wide 24 mm | end | 2.2 m | 1.2 m | 18 px | 20° | 2.9× | 9.2 |
| 9 ft | wide 24 mm | corner | 2.2 m | 1.3 m | 17 px | 18° | 3.2× | 10.9 |
| 9 ft | ultra-wide 13 mm | long side | 2.2 m | 0 m | 17 px | 37° | 1.7× | 5.6 |
| 9 ft | ultra-wide 13 mm | corner | 2.2 m | 0.5 m | 10 px | 22° | 2.7× | 14.6 |
| 7 ft (80 in) | wide 24 mm | long side | 2.2 m | 1.1 m | 27 px | 30° | 2.0× | 4.2 |
| 7 ft (80 in) | wide 24 mm | long side | 1.5 m | 1.6 m | 25 px | 14° | 4.2× | 9.5 |

Findings:
- **Height matters more than lens.** At 1.0–1.5 m the far rail is seen at 3–14°. Positions there are badly conditioned, and balls hide each other (§4.6). A **long side at ≥ 2.2 m** (a light stand or a high shelf) is the recommendation.
- **Wide lens, not ultra-wide.** The 13 mm lens fits closer, but the balls get smaller and the lens distorts much more. Keep 13 mm as a fallback for cramped rooms, with distortion correction mandatory (§3.2).
- **Resolution.** At 1080p, far-rail error is 5–15 mm per pixel. 4K halves it. 1080p with ≤ 0.4 px sub-pixel centres is the default, and §9 targets are set per zone. A 4K-capture/ROI-detect option is part of Q3.
- **Calibrate guidance (no text).** The live preview shows the table outline against the frame, plus a pulsing arrow icon (up = raise, back = move away) until the estimated far-corner mm/px is ≤ 7 and all six pockets are inside the frame.

## 3. Calibration design

### 3.1 Sensors and APIs

| Sensor / API | What it gives | Notes | Source |
|---|---|---|---|
| `builtInLiDARDepthCamera` (iOS 15.4+) | Absolute depth. **Depth** maps: streaming up to 320×240, photo up to 768×576. The paired **colour** video/photo can go up to 4032×3024 | Turn filtering off for CV. Sync drops have been reported (unresolved). Query frame rates per format at runtime | [WWDC22-LIDAR], [AV-LIDAR], [AV-LIDAR-DOC], [FORUM-SYNC] |
| ARKit `sceneDepth` + planes | 256×192 depth + confidence, metric pose per frame | Range is often quoted as ~5 m (secondary source). Reflectance limits on dark cloth are unverified | [ARKIT-DEPTH], [ARKIT-FS], [MED-5M] |
| `AVCaptureConnection.isCameraIntrinsicMatrixDeliveryEnabled` | `K` attached to every sample buffer | Must be set before `startRunning()` | [AV-INTR] |
| `AVCameraCalibrationData.lensDistortionLookupTable` (+ `inverseLensDistortionLookupTable`, `lensDistortionCenter`) | Radial magnification LUT, centre to corner | Delivered only when GDC is **off** on the device and content-aware distortion correction is off | [AV-LUT], [AV-CALDEL] |
| `AVCaptureDevice.isGeometricDistortionCorrectionEnabled` | Apple's built-in GDC | **Defaults to true** where supported | [AV-GDC] |
| `AVCaptureConnection.preferredVideoStabilizationMode` | EIS | Defaults to `.off`. Any other mode adds latency and can change the format | [AV-STAB] |
| `setFocusModeLocked(lensPosition:)` | Fixed focus | The only way to set `lensPosition` | [AV-FOCUS] |
| CoreMotion | Gravity, user acceleration | No entitlement | Apple API |
| Vision | Body pose, person segmentation, trajectories | `VNDetectTrajectoriesRequest` is a fast-ball cross-check only | [VN-TRAJ], [VSEG] |

### 3.2 Camera-model requirements (tracking stream)

These are required, not optional. Each has a test in §10.1 or §10.2.

1. **Stabilization off.** Set `preferredVideoStabilizationMode = .off` and assert `activeVideoStabilizationMode == .off` (KVO) [AV-STAB]. EIS warps and crops each frame, which breaks a fixed homography.
2. **OIS.** The main camera has sensor-shift OIS [SPECS15]. I found no public API to disable it (unverified). On a still tripod it should stay centred. Take per-frame `K` from the sample-buffer attachment [AV-INTR], and let the rail-line residual (§3.6) catch any drift.
3. **Focus, exposure and WB locked** after calibration. Use `setFocusModeLocked(lensPosition:)` at the calibrated position [AV-FOCUS], because focus breathing changes `K`. Exposure follows §4.1 (flicker), with WB locked.
4. **Distortion: GDC off + Apple LUT** (recommended). Turn `isGeometricDistortionCorrectionEnabled` off [AV-GDC]. Read `AVCameraCalibrationData` once at calibration from a photo capture (constituent-photo delivery on, content-aware correction off [AV-CALDEL]). Undistort **detected points only** (not whole frames) with `lensDistortionLookupTable` around `lensDistortionCenter` [AV-LUT]. Scale `intrinsicMatrixReferenceDimensions` to the tracking format. The alternative, GDC on, gives no LUT, so its residual distortion is unknown. That alternative stays acceptable only if replay shows pocket RMS ≤ 2 px. Whether the 1080p60 video crop shares the photo LUT's centre is **unverified**: the K-mismatch and undistort tests below catch a mismatch.
5. **`K` comes from the format actually used for tracking.** If the per-frame `K` drifts from the calibration `K` by more than 0.5% in focal length or 2 px in principal point (est.), the calibration is marked *stale*.
6. **ARKit/LiDAR → AVCapture hand-off.** Formats and intrinsics differ, so **no pose is carried over.** The scan carries over only the metric table size (L, W ± σ). The pose `[R|t]` is re-solved in the AVCapture tracking images from pockets and rail lines, using those images' `K` and distortion, with the table dimensions fixed. That makes the pose metric.

### 3.3 Pipeline (tripod mode, default)

1. **Coarse cloth region.** Region-grow on the dominant chroma on the GPU, giving a cloth mask and its hull.
2. **Rails and pockets.** Undistort the boundary edge points, then RANSAC four cushion-nose lines. Pockets are dark notches. This is the same idea as pix2pockets (0.4 cm single-image ball error, 195 images) [PIX2P]. An optional synthetic-trained keypoint head (6 pockets + 18 diamonds) handles occlusion.
3. **Pose.** PnP with `K`, using pocket mouths and nose lines at z = 0.635·2R. With the table size from §3.4, the pose is metric.
4. **Table size (§3.4)**, then **orientation (§3.5)**.
5. **Homographies.** `H_cloth = K[r1 r2 t]` and **`H_R = K[r1 r2 (R·r3 + t)]`**, both mapping table → (undistorted) image. Detections go image → table through `H_R⁻¹`. The overlay draws ball-height geometry through `H_R` and cloth-level geometry through `H_cloth`, then re-applies distortion for display.
6. **Sphere-projection bias.** The centre of a sphere's image ellipse is not the image of its centre. Correct in **undistorted image space** before applying `H_R⁻¹` (closed form from the tangent cone, needs `K` and range). This is a pure CueCore function.
7. **Quality metrics.** Pocket RMS (px), rail residual (px), metric-source disagreement (%), far-corner mm/px (§2.2). Shown in the debug HUD (D9).
8. **Fallback.** Tap the 4 corner pockets. If no metric source is available, use the D7 visual size picker.

### 3.4 Metric table size (D12)

Planar features give shape but no scale (every table is 2:1). Estimators:

| Estimator | Independence | Error model (est.) | Fails when |
|---|---|---|---|
| **Depth** = LiDAR plane fit ∪ ARKit raycast of pockets | **One correlated source.** On a still tripod ARKit gets no parallax and little cloth texture, so its scale comes from LiDAR. They are never fused as independent | σ ≈ 1–2% of L (to be measured) | Dark/low-reflectance cloth, grazing far rail, range beyond ~3–5 m [MED-5M] (unverified on dark cloth) |
| **Ball size** (object balls only; **cue ball excluded**) | Independent of depth | σ_rand ≈ 0.5–1 px on a 40–120 px limb in a 12 MP still, shrinking ~1/√N; **plus σ_sys ≈ 1–2%** that does *not* average out (specular highlight, contact shadow, residual distortion, blur). Validate per table on real data | Few balls on the table, glare |
| **Rack spacing** (optional, at the break rack) | Uses centres, not limbs, so it avoids limb bias | Frozen-rack centre spacing = 2R. Rack gaps bias it long by 0–2% | Loose rack |

**Fusion:** a robust weighted mean in which each source's variance includes its systematic term. Sources that disagree by more than 3σ are flagged, and the visual picker opens with the closest class pre-selected.

**Classify, then measure.** Known playing lengths: 76, 78 (unverified), 80 | 88, 90, 92 | 100 in.

| Neighbours | Gap | Separable at σ(L) = 1.5%? |
|---|---|---|
| 76 / 78 / 80 | 2.5% | **No.** Midpoint at 0.83σ gives ~20% error per neighbour |
| 88 / 90 / 92 | 2.2% | **No** |
| 80 → 88 (bar box → 8 ft) | 10% | Yes. Boundary at 84 in is ≥ 3.3σ from each, error < 0.1% |
| 92 → 100 (8 ft → 9 ft) | 8.7% | Yes. Boundary at 96 in, ≥ 2.8σ, error ≈ 0.3% |

So: **classify into {bar box, 8 ft, 9 ft}, then use the measured L inside the class** (W = L/2), without snapping to a single preset. A 2.5% length error moves the head string ~1.3 cm on a 7 ft table, which is within rule tolerance. Overlay lines are drawn from image geometry and are nearly scale-free. **Target:** a class confusion matrix on the test tables (≥ 99% diagonal), and the length error is reported, not gated.

**Cue ball size.** On a bar box with an oversized cue ball [CB-OVER], the cue ball's limb-fit diameter is measured separately against the object-ball scale. If it's > +3% (est.), flag "oversized cue ball" to Physics (Q7).

### 3.5 Head vs foot end (orientation)

A 2:1 table is symmetric under a 180° turn. Rails, pockets and diamonds can't tell the ends apart, but Rules needs to. `Table.swift` defines the head end at x = 0, with `headStringX = 0.25 L`, and `RulesEngine.headStringFouls` uses it for break/kitchen ball in hand. The 9-ball three-ball rule counts balls crossing the head string (WPA 5.3(c), see rules-notes). Mesh fusion needs one shared frame.

Cues, strongest first:
1. **Rack position.** A tight cluster of ≥ 9 balls centred within ~10 cm of one of the two candidate foot spots (0.25 L from either end) marks the **foot** end.
2. **Break position.** At the first break, a cue ball at rest behind one candidate head string while a rack sits at the other end confirms it.
3. **Weak cues (unverified, never decisive alone):** branding on a short rail, ball-return/coin mechanism position on bar boxes.
4. **Fallback (no text):** in Calibrate, a top-down table icon with a large arrow pointing at the head end. One tap flips it.

The result is a single bit, `orientationFlipped`, applied as a 180° rotation about the table centre, with a confidence. It is re-checked at every rack (cue 1). If a later rack contradicts it with high confidence, the arrow icon pulses in Calibrate. The bit is never flipped silently mid-game.

**Mesh.** The host's orientation is authoritative. Each peer resolves its own 180° ambiguity by matching its rest-position detections to the host's: it compares assignment cost under identity versus rotation and needs ≥ 4 balls and a cost ratio ≥ 3 (est.). Otherwise the peer withholds detections. A peer whose own rack cue conflicts with the host's raises the arrow on the host (host arbitration).

### 3.6 Handheld mode

ARKit world tracking runs for the whole session. `H_R` is recomputed per frame from the ARKit pose, with the table rectangle and orientation fixed at calibration. Accuracy is degraded (SPEC allows this). Detections are down-weighted in mesh fusion.

### 3.7 Continuous validation

1. **Gravity, not attitude.** Use CoreMotion's gravity vector (pitch/roll). A change > 0.2° sustained 1 s, *or* a user-acceleration shock above a threshold (est. 0.05 g) with 0.5 s debounce, marks the calibration **suspect**. **Yaw is ignored** unless the rail residual confirms it, because it drifts without a magnetometer reference. Triggers are **suppressed during the moving window of a break** and re-evaluated against the rail residual once balls settle.
2. **Rail residual.** At every rest period and ≥ 1 Hz, run an edge pass on the nose lines. A mean residual > 3 px for 2 s marks it **stale**, and a pulsing calibrate icon appears (no text).
3. **Coherent shift.** If all resting balls shift together, the camera moved.
4. **K mismatch** (§3.2.5) → stale.
5. Small drift is re-fit silently from the rails.

### 3.8 Why tripod mode is not ARKit for the whole session

ARKit owns the camera, restricts formats, and costs VIO CPU/GPU for a camera that doesn't move. A short scan followed by `AVCaptureSession` gives full control over format, focus, exposure and distortion. This is a hypothesis for the Phase 3 spike (R4).

## 4. Ball detection and identification

### 4.1 Capture settings

- **Format:** wide camera, 1920×1080 (or 1920×1440 4:3) at 60 fps [SPECS15]. Far-ball sizes are in §2.2. Full resolution is used only for calibration stills. A 4K/ROI option is part of Q3.
- **Exposure and flicker.** Mains-powered fluorescent and some LED lamps flicker at 2× mains (100 Hz / 120 Hz). An exposure that is a multiple of the flicker period gives even brightness [SONY-FLICKER]. Modern LED drivers often flicker at hundreds to thousands of Hz, which averages out within any exposure [SONY-FLICKER].
  - At calibration, measure frame-mean and row-banding oscillation for 1 s. If flicker is found, set exposure to **1/120 s** (60 Hz mains) or **1/100 s** (50 Hz). Blur at 3 m/s is then ~2.5 cm instead of 1.2 cm at 1/250 s. The blur streak is symmetric, so the centroid stays at mid-exposure time and centre accuracy holds. Identity uses rest frames, where blur doesn't matter.
  - If there is no flicker, use ≤ 1/250 s.
  - Either way, **normalise colour per frame** against the cloth and the cue ball (gain + white-point), so the locked-WB identity features stay stable.
- **Rolling shutter.** The main camera reads out in ~5.3 ms (CineD, 300 Hz strobe) [CINED-RS]. A 5 m/s ball moves 2.7 cm across the readout. Each observation is timestamped `t = t_frame + (row / H) · t_readout` (measured per format). Within one ball (≈ 0.1 ms) the skew is negligible.

### 4.2 Detector options and licenses (Q1, neutral)

Context:
- The repo is public but has **no LICENSE file yet**, so a licence must be chosen anyway.
- The app is sideloaded via a Personal Team, with **no store distribution**.
- Synthetic data (§8) is needed under every option, for the hard cases.

| Option | License facts | Effort (est.) | Risk | Gate impact |
|---|---|---|---|---|
| **(a) Ultralytics YOLO26 + release the repo under AGPL-3.0** | Ultralytics states that all YOLO-trained models fall under AGPL-3.0 and that compliance means releasing the complete source of the whole derivative work [UL-LIC]. This is **Ultralytics' stated position**, not a settled legal question. Native `coreml` export, `quantize=8`, NMS-free head [UL-COREML], [YOLO26] | Low: days to a first model | Low technical risk. Licence obligations bind everyone who redistributes builds. AGPL + a future App Store release would need a separate legal check (unverified) | Fastest to the Phase 3 gate |
| **(b) Own CenterNet-style heatmap net + permissive licence** | Our code. Backbone: train from scratch (no weight licence) or use pretrained weights, whose licences vary per model (torchvision/timm weights carry the dataset's terms, e.g. ImageNet's research-use terms; unverified per model) | High: ~3–6 weeks for net + training + tuning | Medium–high: accuracy unproven, sim-to-real gap | Likely slips the Phase 3 gate by weeks |
| **(c) YOLOX-nano/tiny + permissive licence** | Apache-2.0 per model cards (upstream unverified). COCO-pretrained weights: COCO annotations are CC BY 4.0, while image rights vary (unverified) [YOLOX-RF], [YOLOX-HF] | Medium: ~1–2 weeks (Core ML conversion is not first-party; ~22 ms reported for YOLOX-S at 640 on a 17 Pro, so nano is needed) | Medium | Moderate slip |
| (d) MIT-YOLOv9 | MIT repo. The original YOLOv9 is GPL-3.0, so take weights only from the MIT repo [MIT-YOLO] | Medium | Medium | Moderate |
| (e) Ultralytics Enterprise licence | Paid, priced by quote [UL-LIC] | Low | Cost | Fast |
| Create ML Object Detector | We own the model. YOLOv2-based full network [CREATEML] | 1 day | Weak on small balls | Baseline / auto-labeller only |
| RF-DETR, D-FINE | Apache-2.0 (some RF-DETR sizes are PML 1.0) [RF-DETR], [RF-DETR-LIC], [DFINE-RF] | Unverified Core ML path | ANE op risk | Not first choice |

Whatever Q1 decides, Phase 3 starts with a 1-day Create ML baseline and a classical cloth-segmentation baseline as auto-labellers and comparators.

### 4.3 Where detection runs: undistorted camera image

The earlier "rectified crop" idea is **dropped**. Warping through `H_R` stretches each ball away from the camera by ~1/sin(elevation), which is 2–6× at the elevations in §2.2. The blob centre also stops being the ball centre.

Design:
- **Input:** the table-ROI bounding box from the raw frame, letterboxed into a fixed tensor (e.g. 1536×768, no downscale at 1080p), so the ANE shape is fixed.
- **Ball sizes in the input:** 17–60 px, near-circular (a sphere's image elongates only ~1/cos of the off-axis angle, ≤ 1.15 on the wide lens, est.).
- **Pipeline:** heatmap peak + sub-pixel offset → undistort the point (§3.2.4) → sphere-bias correction (§3.3.6) → `H_R⁻¹` → table. Per-observation σ comes from the local mm/px Jacobian (§2.2).
- **Synthetic training** uses raw camera views across the placement envelope, so it learns the true image appearance.

### 4.4 Identity: cue, 1–15, solid vs stripe

1. **Detector class head** (17 logits: cue, 1–15, unknown).
2. **Crop classifier** at 10 Hz and on uncertain tracks. A 48×48 crop from the full-resolution frame goes to a tiny CNN, with hue histogram, stripe white-ratio and number-circle score as extra inputs.
3. **Temporal + global inference in CueCore.** A Bayes posterior per track, then Hungarian uniqueness (each ID at most once, pocketed balls gone, game-state priors).

**Synthetic hard cases:**
- 1/9 (yellow); 3/7/5 and their stripe twins 11/15/13; 2/4 under warm light
- **6/14 (green) on green cloth**
- **8 against dark pockets and shadows**
- **cue ball vs white stripe bands and specular highlights**
- stripe balls showing an almost solid face
- oversized cue ball

Per-table colour calibration uses the cloth white point, lamp colour temperature and the cue-ball reference.

### 4.5 Cue stick, live aim and stroke

**Cue-line detector** (Perception, not Overlay). Live aim (§5.6), called-pocket inference (§3 WPA) and stroke start all depend on it.
- **Constraint:** the cue runs from the **back (grip) hand through the bridge hand** to the cue ball, not along the forearm. Body pose [VN] at 15 Hz gives both wrists. The search corridor is the segment from back wrist to bridge hand, extended to the cue ball.
- **Primary:** a constrained line fit on thin-edge responses inside that corridor, with the end point snapped to the cue-ball track.
- **Upgrade if the fit fails replay:** a small keypoint head (butt, ferrule/tip) trained on synthetic players.
- **Partial pose** (bent player, far tripod): a corridor from any visible hand to the cue ball, at lower confidence.
- **Accuracy needed.** A cue-direction error δ moves the contact point by ≈ d·δ. Over 2R that turns into an object-ball direction error of ≈ d·δ / (2R·cos θ). For d = 1 m and δ = 1°, that is ~17° (est.), close to adjacent-pocket separation. **Target:** cue direction ≤ 0.5° median, ≤ 1.5° p95 at stroke start, measured on replays against labelled cue lines.
- **Called pocket (WPA)** = the pocket that best matches the predicted object-ball line at stroke start, combined with the Engine's candidate prior (which pockets are makeable from this cue line). The locked pocket glows, and the shooter can tap to override (SPEC). Replay metric: **called-pocket accuracy ≥ 95%** (est. target).
- **Cue not visible:** no live line, suggested line only. Called pocket = the Engine's best candidate for the struck ball, at low confidence → post-shot confirm if a ball drops (Q2).
- **Stroke start:** the tip approaches the cue ball, and the segmenter's motion gate fires (§5.2).

### 4.6 Clustered and occluded balls

At 10–30° elevation, rack clusters and frozen balls overlap in the image.
- The detector is trained on synthetic racks, frozen pairs and rail-frozen balls with visibility labels.
- Metrics are reported **by visibility bucket** (≥ 90%, 50–90%, < 50%).
- The tracker keeps occluded rest balls at their last position, with growing σ, and never deletes them while occluded.

## 5. Tracking and shot segmentation

### 5.1 Tracker (CueCore, table frame)

- **State per track:** position, velocity, mode {rest, moving, manual, pendingSpot}, ID posterior, missed count. Each observation carries its own σ_i (§4.3).
- **Model:** constant velocity with a rolling-deceleration prior, and cushion reflection in the predict step. **Its restitution and friction are deliberately loose priors, not Physics' exact values.** Process noise inflates after collisions.
- **Association:** gated Mahalanobis distance + ID cost, solved Hungarian. The gate widens where tracks meet.
- **Detector rate:** **60 Hz while the segmenter is `moving`/`settling`; 15 Hz at `rest`/`armed`** (§6). If 60 Hz full-frame does not fit the budget, the fallback is 30 Hz full-frame plus 60 Hz batched window crops (≤ 16 × 96², ~1/8 of the pixels). Its recall on blurred balls must be shown on synthetic and real breaks before use.
- **Breaks:** physics seeding does **not** solve a 16-ball break, which is chaotic. Break fields default to **low confidence** (§5.3) and go to mesh fusion or Q2 confirmation unless replay metrics prove otherwise.
- **Occlusion:** tracks coast inside the projected body-pose region. A track that disappears while occluded is never declared pocketed unless it is inside a pocket zone (§5.4).
- **Out-of-play detections:** detections outside the playing polygon inset by R (pocket nets, ball returns, balls in hands, balls on rails) are ignored for state.

### 5.2 Rest/motion from the noise model (derivation)

Assume a per-frame position noise of σ = 3 mm (the §10.1 fixture value; the real σ_i comes from each observation) at 60 Hz.
- **Finite-difference speed is unusable:** σ_v = √2·σ·60 ≈ **0.25 m/s**. That crosses any 0.1 m/s threshold all the time.
- **Rest test:** a least-squares velocity over a window of N = 30 frames (0.5 s). σ_slope = σ / √(Σ(t − t̄)²) with Σ(t − t̄)² = N(N² − 1)/12 · Δt² = 0.624 s², so **σ_slope ≈ 3.8 mm/s per axis**. A ball is *at rest* if its fitted speed is < 12 mm/s (≈ 3.2σ) **and** its net displacement (5-frame means at the window ends) is < 6 mm (≈ 3σ of the mean difference) for **2 consecutive windows** (hysteresis). A rolling ball at 12 mm/s stops within ~0.1 s (μ_roll ≈ 0.01, est.), so the end-of-shot latency is ~0.5–1.0 s.
- **Motion start (shot):** only in `armed`. A ball's position minus its rest anchor (mean of the last 30 rest frames, σ ≈ 0.55 mm) exceeds **4σ_i (12 mm) on 2 consecutive frames**. The false-alarm rate per ball-frame is ≈ (e^(−8))² ≈ 1·10⁻⁷, so < 0.03 expected per hour for one ball. A 1.3 m/s shot crosses 12 mm within one frame. The shot start time is back-extrapolated to sub-frame precision by a linear fit of the first moving frames, intersected with the anchor.
- **Thresholds scale with σ_i**, so far-rail balls (larger σ) get proportionally wider bands. All values are parameters and are re-derived if the measured σ differs.

### 5.3 Segmenter states

```
idle ──(person within reach of CB, pose)──▶ armed ──(CB motion gate + impulsive profile)──▶ moving ─▶ settling ─▶ pocketHold(5 s) ─▶ rest → emit ShotOutcome
  ▲                                           │
  │                                           └─(motion with hand-on-ball / non-physical profile)─▶ manual
  ├── ballInHand  (RuleResult.ballInHand ≠ .none): CB may vanish (hand occludes) and reappear; any CB placement → new pre-shot state, no ShotOutcome
  ├── spotting    (RuleResult.spot non-empty, e.g. the 9 after a foul, D13): wait for that ID at the foot spot (or behind it if blocked); until then the ball is pendingSpot
  └── reracking   (re-rack result, D15 B2 same breaker / new rack): every ball may move; wait for a rack cluster at the foot spot + rest, then isBreak = true
```

- **Hand-on-ball veto.** Motion is `manual`, not a shot, when any of these hold:
  - (a) a wrist keypoint, projected to the table with its uncertainty, is within ~10 cm of the moving ball and the ball is occluded or leaves the plane (it disappears, or its apparent size changes);
  - (b) the speed profile is non-physical (no impulsive start, constant speed, then an abrupt stop);
  - (c) the ball reappears somewhere far from its predicted path.

  A real stroke has an impulsive start while the ball stays visible, with the bridge hand close but static.
- **Manual moves outside BIH/spot/rerack** emit `ballDisturbed(ids)`. Rules decides whether it's a foul (WPA 3.6 touched ball, flagged for manual confirmation per rules-notes). The new positions replace the old ones.
- **Pocket confirm window (WPA 2.2):** a ball is pocketed when its track enters a pocket capture zone moving toward the pocket and disappears within 0.3 s, then stays unseen on the playing polygon. A ball still visible in the jaw at rest starts the **5 s hold**. It counts as pocketed only if it drops within those 5 s. A later drop is "settled", handled by WPA 1.8 restore as a manual override. A rebound out of the pocket counts as on-table.
- **Balls removed from pockets** are outside the playing polygon, so they are ignored.

### 5.4 Building `ShotOutcome` (INTERFACES Rules)

| Field | Inference | Confidence default |
|---|---|---|
| `isBreak` | From `GameState.phase == .breakShot` or the reracking state. Not perception | n/a |
| `isPushOut` | **Declared, not inferred.** A pre-shot push-out icon tap while `phase == .pushOutAvailable` (WPA 5.4 requires announcing it). UI is Q6 | n/a |
| `firstContact` | The first object-ball track whose fitted speed rises while within 2R + ε of the cue-ball track. Physics replay breaks ties | Normal. **Low on the break** |
| `pocketed` | §5.3 pocket window + 5 s hold | Normal |
| `offTable` | The track leaves the playing polygon outside pocket zones, or ends off it (WPA 2.6) | Normal (rare) |
| `anyRailAfterContact` | **Rail contact** for ball i after first contact: distance to a nose line reaches ≤ R + ε (ε = max(3 mm, 2σ_i)) while the normal velocity is ≤ 0, followed by a normal-velocity flip *or* coming to rest inside the band. **Frozen-at-start balls** (pre-shot distance ≤ R + ε_f) count only if they leave the band by ≥ 1 cm and return (WPA 2.7). Pocketed/off-table balls count as driven to a rail (2.7) | Normal |
| `objectBallsToRailOnBreak` | Distinct object balls with a rail contact during the break | **Low by default** → mesh fusion or Q2 |
| `calledPocket` | §4.5 | From §4.5 |
| Head-string crossings (three-ball rule, WPA 5.3(c)) | Count balls whose centre crosses `headStringX` during the break (needs §3.5 orientation) | Medium |

**Frozen state:** `possiblyFrozen` is recorded per ball pre-shot. Depth mm/px (§2.2) can't resolve sub-mm gaps, so the rule is "not frozen unless declared" (WPA Reg 26). A possibly-frozen ball glows faintly pre-shot so a player can tap-declare it (rules-notes 2.7). Uncertain fields are never guessed; they go to Q2.

## 6. Performance budget (A17 Pro, 60 fps frame = 16.7 ms)

All numbers are est. targets, to be measured with `os_signpost`, the Core ML/Core AI performance report and Instruments on the 15 Pro Max. **Burst numbers overstate sustained throughput.** Ultralytics notes that sustained camera use runs slower because of capture and scaling plus thermal settling [UL-COREML].

### 6.1 Per stage

| Stage | Rate | Unit | Budget |
|---|---|---|---|
| Capture + Metal texture | 60 Hz | ISP | ~0 CPU |
| Detector on ~1536×768 ROI (own net or n-class, 8-bit) | 60 Hz moving / 15 Hz rest | ANE | ≤ 8 ms (sets the net size. YOLO26n@640 is 3.7 ms burst on a 17 Pro [UL-COREML], so a 2.9×-pixel input on an older ANE may *not* fit; the own net must be smaller, or use the §5.1 window fallback) |
| Point undistort + bias + `H_R⁻¹` | per detection | CPU | ≤ 0.1 ms |
| Identity crop classifier | 10 Hz + on demand | ANE | ≤ 2 ms |
| Tracker + assignment + ID filter + segmenter | 60 Hz | CPU | ≤ 0.6 ms |
| Body pose + cue line | 15 Hz (armed only) | ANE/GPU (Vision decides) | ≤ 10 ms. **Shares the ANE with the detector** |
| Calibration edge pass | ≤ 1 Hz | GPU | ≤ 2 ms |
| Preview + overlay render (same buffer) | 60 Hz | GPU | ≤ 3 ms |
| **HEVC rolling video buffer** (SPEC §5.7) | 60 Hz | Media engine (VideoToolbox hardware) | ~1 ms CPU per frame (est.), plus memory for ~60 s of buffer |
| **Mesh detections** (`BallObservation`) | 60 Hz | CPU/radio | ~16 × 40 B × 60 ≈ 40 KB/s, negligible |
| **Best-angle clip transfer** (D3, ~5 s HEVC ≈ 5–6 MB est.) | after settle, ≤ 1 per shot | radio/CPU | Background QoS, never while aiming |
| **Engine Monte Carlo** (§5.5, host only) | 2–4 s burst after each shot | CPU | Capped at 4 of 6 cores, utility QoS. Runs while balls settle and the detector drops to 15 Hz |
| Foundation Models | post-game only | ANE/GPU | Never concurrent with live tracking |
| Model sizes | | disk | detector ≤ 4 MB, classifier ≤ 1 MB |

### 6.2 Duty cycle and thermal (est.)

An assumed game mix: 60% armed/aiming, 15% moving/settling, 25% idle.
- **ANE:** aiming = detector 15 Hz × 8 ms (12%) + pose 15 Hz × ≤ 10 ms (≤ 15%); moving = 60 × 8 ms (48%). Weighted average ≈ 25%.
- **CPU:** Engine bursts ~3 s per shot every ~30 s ≈ 10% of 4 cores, plus tracker, encode and mesh.
- **Thermal policy:** on `.serious`, lower the moving-state detector to 30 Hz with window crops, the classifier to 5 Hz, and pose to 10 Hz. Cap the Engine at 2 cores. **The preview/overlay frame rate is never reduced** (Phase 9: ≥ 24 fps). Proven only by the 1-hour soak on the 15 Pro Max (§10.4).

### 6.3 Latency and preview sync

- **The preview is rendered by us from the same processed `CVPixelBuffer` that produced the overlay**, timestamp-matched in one Metal pass. Lines and image are then always in sync. `AVCaptureVideoPreviewLayer` is **not** used in game: it would show the image ahead of the lines by the processing latency.
- **Glass-to-display latency (est., to be measured):** exposure + readout (~1 frame) + ISP delivery (~1 frame) + processing (≤ 12 ms) + render/display (1–2 refreshes) ≈ **50–70 ms**. The target is p95 ≤ 70 ms, marked est. Measure it on the 15 Pro Max with an LED-in-frame test.

### 6.4 Model runtime on iOS 27

- **Core ML:** Apple's iOS docs list `MLModel` with no deprecation marker; only `MLModelCollection` is deprecated [CML-DOC], [CML-MLMODEL].
- **Core AI:** new in iOS 27.0 ("Run AI models in your app on Apple silicon"). It uses `.aimodel` assets converted with the Core AI PyTorch extensions, AOT compilation (`xcrun coreai-build`), and runs on CPU/GPU/Neural Engine [COREAI-DOC], [WWDC26-324], [WWDC26-326]. Apple's Core AI page points to Core ML for non-neural model types. Neither WWDC26 session addresses `.mlpackage` migration.
- **Decision:** both paths are supported on iOS 27. Ship `.mlpackage` + `MLModel` first (mature `coremltools`, existing exports such as [UL-COREML]). Spike a Core AI conversion of the same net in Phase 3 and compare ANE latency. The runtime stays behind `BallDetector`.

## 7. Datasets

**Rule (D5):** no third-party images are committed. `tools/perception_data/manifest.json` records the URL, version, licence, attribution and class map for each set. A download script runs dev-time only into a git-ignored directory. If shipped weights use CC BY data, the acknowledgements carry the attribution.

| Dataset | Content | License (as listed) | Status |
|---|---|---|---|
| Roboflow pool sets (main-cpmku, bastogne-billiards, pool-tracking, ben-gann, cuebit, skylep, adam-shortland, cueball, nadnq) | 16–22 ball classes. cuebit adds cue/table | CC BY 4.0 per listing (uploader claims) [RF-SEARCH], [RF-SEARCH2] | Confirm manually. Never committed |
| **pix2pockets** (DTU) | 195 in-the-wild images, 5,748 masks incl. table dots | **Paper** (arXiv 2504.12045) is CC BY 4.0. That covers the paper only. The **dataset** licence is not stated on the l530o page. A related Roboflow set lists CC BY 4.0 [PIX2P], [PIX2P-RF] | Benchmark only until the dataset licence is confirmed |
| Roboflow "Nine-balls-segmentation" | 9-ball seg | Not checked | To check |
| **Our synthetic set** (§8) | Unlimited, exact labels | Ours [BLENDER-LIC] | Commit a small golden subset |
| **Our in-app data collection** (SPEC §12) | Real frames | Personal | See below and Q5 |

**Data-collection privacy (Q5).** Tripod frames capture every player and bystander, while SPEC §2 makes appearance data opt-in per player. Proposed default:
- Save only **table-ROI crops with people masked out** (`VNGeneratePersonSegmentationRequest` or instance masks [VSEG]) at capture time, on device. Nothing is ever committed.
- Off-device transfer (AirDrop to the Mac) is a separate explicit action.
- Unmasked frames would require consent from everyone in view. That is a product decision (Q5).

## 8. Synthetic data

**Generator:** headless Blender driven by our own script (Blender output is ours [BLENDER-LIC]. BlenderProc is GPL-3.0 [BLENDERPROC], so it is avoided. pooltool, Apache-2.0 [POOLTOOL], is an alternative renderer). Scenes come from our `Simulator`: racks, broken layouts, mid-shot frames, and full 60 fps shot clips with exact ground-truth `ShotOutcome`.

**Randomisation:**
- **Scene:** cloth colour and wear; our own ball textures (no logos); lamp type, count, height and colour temperature (2700–6500 K); **flicker** (100/120 Hz amplitude, phase) and **rolling-shutter row timing** (3–8 ms readout).
- **Camera:** poses over the §2.2 envelope (height 1.0–2.6 m, sides, ends, corners, ±15° roll) + handheld jitter; **lens distortion from real LUT shapes**; noise, HEVC artifacts; motion blur from velocity × exposure.
- **Occluders and contact:** mannequins, cues, hands, chalk, drinks; **hands holding or placing balls** (for the manual-move veto).
- **Hard cases:** clustered racks and frozen pairs at low elevation; balls in pocket jaws; stripe orientation; the §4.4 identity hard cases; an oversized cue ball.

**Labels:** 2D centre (true projected centre, not blob centre), radius, ID, visibility fraction, table coordinates, pocket/diamond keypoints, cloth mask, `K`, distortion, pose, `H_R`, cue keypoints.

**Volume (est.):** 50–100 k raw-view stills plus clips. Cycles on the Metal GPU takes ~1–3 s per image; EEVEE is ~10× faster for bulk. Pretrain on synthetic, fine-tune on licensed and masked local data. **Only held-out real metrics count for the gate.**

## 9. Training pipeline and targets

1. `tools/perception_train/`: `uv` + PyTorch on MPS.
2. Export with `coremltools` `ct.convert`, using fixed shapes, FP16, then 8-bit palettization [CT-OPT]. Avoid dynamic shapes and gather/scatter-heavy ops (community guidance, unverified) [CT-COMM]. Run a Core AI conversion spike (§6.4).
3. Validate with `CPU_AND_NE` in Python, then the on-device performance report. Golden parity within 1e-2 on 50 inputs.
4. Version the models with a hash and a JSON model card (data mix, licences, metrics, date).

| Metric | Target | Gate link |
|---|---|---|
| Detector recall / precision, ≥ 90%-visible balls at rest | ≥ 99.5% / ≥ 99.5% (reported per visibility bucket, §4.6) | identity ≥ 95% |
| Centre error at rest, **near half** of the table | ≤ 3 mm median, ≤ 6 mm p95 | Phase 4 overlay |
| Centre error at rest, **far half** | ≤ 0.4 px reprojected, which is ≈ 3–6 mm at the recommended placement (§2.2) | Phase 4 |
| Centre error moving (≤ 3 m/s) | ≤ 15 mm p95 | |
| Identity per crop / per track | ≥ 90% / ≥ 98% | gate ≥ 95% |
| Table size | Class confusion matrix ≥ 99% diagonal; length error reported (§3.4) | D12 |
| Orientation (head/foot) | 100% after the first rack on test tables; the fallback tap is always available | Rules |
| Calibration pocket reprojection (after undistort) | ≤ 2 px RMS | |
| Shot start / end | ±1 frame / end ≤ 1.0 s after true rest | "correct in replays" |
| firstContact, pocketed, rail-after-contact (non-break) | ≥ 97%, ≥ 99%, ≥ 97% | rules |
| Break fields | Measured and reported; low confidence until proven | R3 |
| Manual-move veto | 0 bogus `ShotOutcome`s on BIH/spot/rerack replays | rules |
| Cue direction at stroke start | ≤ 0.5° median, ≤ 1.5° p95 | live aim |
| Called pocket (WPA) | ≥ 95% | rules |
| Throughput | Moving-state detector 60 Hz, overlay 60 Hz, 1 h without dropping below 24 fps | gate + Phase 9 |

## 10. TDD and QA plan

### 10.1 CueCore (`swift test`, written first)

| Unit | Red tests (examples) |
|---|---|
| `Homography` | Round-trip on random cameras. Collinear input is rejected. Noise robustness |
| `CameraModel` / `BallPlaneHomography` | `H_R` equals `K[R|t]` at z = R. z = 0 reduces to `H_cloth` |
| `LensDistortion` (LUT model) | **Undistort ∘ distort round-trip** < 0.05 px over the frame with a synthetic LUT. Identity LUT is a no-op. Scaling the reference dimensions to the 1080p crop is consistent |
| `IntrinsicsMonitor` | **K mismatch** (focal +1%, principal point +5 px) → stale. Jitter within tolerance → ok |
| `SphereProjectionBias` | Analytic vs projected centre on synthetic spheres. Zero on the optical axis. Applied in undistorted space |
| `TableSizeEstimator` | Correlated depth sources aren't double-counted. Ball-size σ_sys floors the fused σ. **76/78/80 → bar-box class; 88/90/92 → 8 ft; 100 → 9 ft**, using the measured L. A cue ball in the input set is excluded. 3σ disagreement is flagged |
| `TableOrientationResolver` | **A 180°-rotated calibration with a rack near the "wrong" foot spot is detected and flipped.** Symmetric/no-rack input → `.unknown` (fallback tap). A peer's rest positions under 180° rotation vs the host's resolve to flipped, and < 4 balls → withheld |
| `CalibrationHealth` | 0.5° gravity tilt → suspect then stale. Yaw-only drift → ok unless the rail residual rises. A shock during the break window is suppressed, then re-checked |
| `BallTracker` | **Smoke:** Simulator traces + σ = 3 mm noise, 5% dropouts, occlusions, swaps. **Robustness:** traces from a mismatched Simulator (e_c ∈ [0.70, 0.95], friction ±30%, cushion height ±3 mm, throw on/off) while the tracker keeps its default priors; tracks must still stay within tolerance and IDs survive |
| `RestDetector` / `ShotSegmenter` | With σ = 3 mm noise, a static table produces 0 false starts over 1 h of synthetic frames. True starts are detected within 1 frame for ≥ 0.2 m/s. Rest is declared ≤ 1.0 s after true rest. Thresholds follow σ_i |
| `ShotSegmenter` states | BIH placement, spotted 9, re-rack, a hand-carried cue ball, a ball bumped by hand, a ball hanging 3 s then dropping (pocketed), hanging 6 s then dropping (not pocketed, WPA 2.2) → correct events, no bogus `ShotOutcome` |
| `OutcomeBuilder` | 500 random sims: noisy-track outcome equals true-trace outcome (≥ 97% per field). Frozen-to-rail-at-start ball that doesn't leave → no rail credit (WPA 2.7). Ball that rolls in and stops frozen → rail credit. Break fields carry low confidence |

### 10.2 App target (XCTest, `CueCoach iPhone 15 Pro` simulator, function only)
- Colour/stripe features on committed synthetic crops. Model I/O contract on golden frames.
- `FrameSource` replay determinism.
- Capture configuration assertions (device only, skipped in the simulator): stabilization `.off` is active, GDC off, focus locked, intrinsics delivery on.

### 10.3 Replay QA (SPEC §12)
- **Clips:** committed synthetic clips with exact truth, plus real clips outside git (D5) with `*.truth.json` sidecars.
- **Harness:** deterministic and real-time-with-drops modes. Emits metrics JSON (§9). Regression fails on any threshold.
- **Coverage matrix:** 7/8/9 ft × cloth colours × {side, end, corner} × {1.5, 2.2, 2.6 m} × lighting (incl. **flicker** lamps) × {break, soft cut, power shot (rolling shutter), bank, scratch, off table, occluded shot, **BIH placement, spotted 9, re-rack, hand-bumped ball, jaw-hang late drop, frozen-to-rail ball, clustered rack**}.

### 10.4 Device QA (D6)
- **15 Pro Max:** stage timings, ANE residency, measured latency (LED test), and a **1-hour thermal soak with the full concurrent load** (encode, mesh, Engine bursts, pose). Calibration on ≥ 3 real tables incl. The Rive (D7), including dark cloth and far placement to check LiDAR failure and fallback.
- **17 Pro Max:** second mesh view. Orientation agreement with the host, and the same metrics.

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Licence choice (Q1) | Decide before training starts. Runtime-agnostic `BallDetector` |
| R2 | Synthetic-to-real gap | Heavy randomisation, real fine-tune, gate on real metrics |
| R3 | Break tracking (chaotic, fast, clustered) | 60 Hz detector in moving state, low-confidence break fields, mesh second view, Q2/Q3 |
| R4 | LiDAR fails (dark cloth, range, grazing) or sync drops | Depth is one source among three. Ball size + rack spacing, then the visual picker |
| R5 | Identity hard cases (green on green, 8 in shadow, stripe face) | Hard-case synth, temporal posterior, uniqueness, multi-view |
| R6 | Occlusion by players | Coasting, never infer a pocket from disappearance alone, mesh |
| R7 | Tripod bump / drift / OIS / focus | Gravity + shock monitor, rail residual, K monitor, locked focus |
| R8 | ANE contention (detector + pose) and sustained < burst | Rate schedule by state, thermal policy, sustained measurements |
| R9 | Low tripod placement → poor far-rail accuracy | §2.2 guidance cue, per-zone targets, 4K option (Q3) |
| R10 | Called-pocket error from small cue-angle error | Engine prior, glow + tap override, Q2 |
| R11 | Dataset provenance / privacy | Manifest only, masking, Q5 |

## 12. Proposed interface additions (for the head orchestrator, not applied)

```swift
// CueCore
public struct Homography { var m: simd_double3x3; func apply(_ p: Vec2) -> Vec2; var inverse: Homography
                           static func dlt(_ src: [Vec2], _ dst: [Vec2]) -> Homography? }
public struct LensDistortion: Codable, Sendable { var lut: [Float]; var inverseLUT: [Float]; var center: Vec2
                           var referenceSize: Vec2; func undistort(_ p: Vec2) -> Vec2; func distort(_ p: Vec2) -> Vec2 }
public struct CameraModel { var K: simd_double3x3; var distortion: LensDistortion?; var R: simd_double3x3; var t: SIMD3<Double>
                            func planeHomography(z: Double) -> Homography }      // table(z) → undistorted image
public enum TableOrientation: Codable, Sendable { case asCalibrated, flipped, unknown }
public enum TableOrientationResolver { static func fromRack(_ balls: [Vec2], spec: TableSpec) -> (TableOrientation, Double)
                                       static func alignPeer(_ peer: [Vec2], host: [Vec2], spec: TableSpec) -> (TableOrientation, Double) }
public struct TableCalibration: Codable, Sendable { var camera: CameraModel; var spec: TableSpec; var orientation: TableOrientation
                            var sizeClass: TableSizeClass; var quality: CalibrationQuality; var timestamp: Double }
public enum TableSizeClass: Codable, Sendable { case barBox, eightFoot, nineFoot }
public enum TableSizeEstimator { static func fuse(_ e: [SizeEstimate]) -> (spec: TableSpec, cls: TableSizeClass, sigma: Double, conflict: Bool) }
public struct BallObservation: Codable, Sendable { var t: Double /* row-corrected */; var table: Vec2; var sigma: Vec2
                            var classLogits: [Float]; var confidence: Float; var visibility: Float; var sourcePeer: Int }
public struct BallTracker { mutating func update(_ obs: [BallObservation], at t: Double) -> [Track] }
public struct ShotSegmenter { mutating func ingest(_ tracks: [Track], pose: [HandPoint], rules: RuleResult?, at t: Double) -> SegmenterEvent? }
   // .started(t), .ended(ShotOutcome, TrackLog, confidence: [Field: Double]), .ballDisturbed([BallID]),
   // .placed(BallID, Vec2), .spotted(BallID), .reracked
// App
struct CameraFrame { var pixelBuffer; var time: Double; var intrinsics: simd_float3x3?; var depth: AVDepthData? }
protocol TableCalibrator { func calibrate(_ s: FrameSource, taps: [CGPoint]?) async throws -> TableCalibration
                           func health(_ f: CameraFrame, motion: CMDeviceMotion?) -> CalibrationHealth }   // .ok/.suspect/.stale
protocol BallDetector { func detect(_ f: CameraFrame, _ c: TableCalibration) async -> [BallObservation] }
protocol CueLineDetector { func detect(_ f: CameraFrame, pose: VNHumanBodyPoseObservation?, cueBall: Vec2) -> CueLine? } // dir + confidence
```

**Cross-track note (Geometry).** Settled (audit G1): the frame is head-left origin, +x toward the foot (`headStringX = 0.25 L`, `footSpot = 0.75 L`), and INTERFACES now says so. Perception's orientation bit (§3.5) maps into this frame.

## 13. Open questions for the user

- **Q1 Detector licence.** Facts: the repo has no licence yet and is public; the app is sideloaded, with no store. Options with costs are in §4.2:
  - (a) AGPL-3.0 repo + YOLO26: days, low risk, AGPL obligations;
  - (b) permissive repo + own net: 3–6 weeks, accuracy risk, likely gate slip;
  - (c) permissive repo + YOLOX/MIT-YOLO: 1–2 weeks, medium risk;
  - (d) Enterprise licence: paid.

  No option is pre-picked.
- **Q2 Uncertain fouls and break fields.** When tracking can't tell (occlusion, thin hit, break rails, uncertain called pocket): show a post-shot visual confirm (ball/pocket icons, one tap on any phone), or fall back silently to "no foul"?
- **Q3 Frame rate / resolution.** 1080p60 (default), 120 fps slo-mo for the whole session (better breaks, more heat), or 4K60 capture with ROI detection (halves far-rail error, more bandwidth and heat)? To be measured in the Phase 3 spike.
- **Q4 Table size within a class.** Use the measured length within the bar-box / 8 ft class (recommended, since 76/78/80 and 88/90/92 can't be told apart reliably), or always snap to one preset per class?
- **Q5 Data-collection privacy.** Is masked table-ROI-only capture (proposed default) acceptable? May masked crops be AirDropped to the Mac for fine-tuning? Is unmasked capture ever allowed, and with whose consent?
- **Q6 Push-out declaration.** WPA 5.4 requires announcing a push-out. OK to use a pre-shot push-out icon (tap on any phone) shown only while push-out is available?
- **Q7 Oversized/magnetic cue ball.** When an oversized cue ball is detected, should Physics switch to a larger, heavier cue-ball model, or just warn (icon) that predictions are less accurate?
- **Q8 Placement.** Is asking players to mount the phone at ≥ 2.2 m (light stand or shelf) acceptable, with the "raise / move back" cue, or must low tripods be fully supported at lower accuracy?
- **Q9 Touched balls.** Should a hand-moved ball outside ball in hand (`ballDisturbed`) prompt a foul confirm (WPA 3.6), or be ignored in bar rules?

---

## Sources

| Key | Source | URL |
|---|---|---|
| WPA-EQ | WPA Tournament Table & Equipment Specifications (poolroom.com mirror) | https://www.poolroom.com/tournament-table-equipment-specifications/ |
| VALLEY | Game Room Shop, Valley Panther Highland Maple (93" = 80×40 in, 101" = 88×44 in play area; dealer page) | https://gameroomshop.com/products/valley-93-panther-highland-maple-pool-table-home-use |
| BRUNSWICK | PoolTables.com, Brunswick Black Wolf Pro 7' (76×38 in internal play area; dealer page) | https://www.pooltables.com/products/brunswick-black-wolf-pro-pool-table |
| DIAMOND | Seyberts, Diamond Pro-Am (8' 45×90 in, 9' 50×100 in play area; dealer page) | https://seyberts.com/products/diamond-pro-am-pool-table |
| OLHAUSEN | Olhausen outside table dimensions sheet (78×39 in 7 ft per search snippet; fetch returned 403, unverified) | https://www.olhausenbilliards.com/wp-content/uploads/2021/03/Outside-Table-Dimensions_2019.pdf |
| CB-OVER | PoolDawg, Action Oversized Cue Ball (older bar tables) | https://www.pooldawg.com/action-oversized-cue-ball |
| CB-HSW | HowStuffWorks, coin-op ball return (oversized vs magnetic cue ball) | https://electronics.howstuffworks.com/question495.htm |
| DD-SPEED | Dr. Dave, CB speed for a range of shots | https://drdavepoolinfo.com/?p=2486 |
| DD-BREAK | Dr. Dave, Billiards Digest Jan 2017 (break speed) | https://billiards.colostate.edu/bd_articles/2017/jan17.pdf |
| A17 | Wikipedia, Apple A17 Pro (cites Apple newsroom) | https://en.wikipedia.org/wiki/Apple_A17_Pro ; https://web.archive.org/web/20230912221839/https://www.apple.com/newsroom/2023/09/apple-unveils-iphone-15-pro-and-iphone-15-pro-max/ |
| SPECS15 | Apple, iPhone 15 Pro Technical Specifications | https://support.apple.com/en-us/111829 |
| CINED-RS | CineD, iPhone 15 Pro lab test: rolling shutter (main 5.3 ms) | https://cined.com/iphone-15-pro-lab-test-rolling-shutter-dynamic-range-and-exposure-latitude/ |
| SONY-FLICKER | Sony support, reducing flicker (shutter matching 50/60 Hz; LED high-frequency flicker) | https://support.d-imaging.sony.co.jp/support/ilc/flicker/01/en/ ; https://www.sony.ca/en/electronics/support/e-mount-body-zv-e-series/articles/00008839 |
| WWDC22-LIDAR | WWDC22 110429, iOS camera capture advancements | https://developer.apple.com/videos/play/wwdc2022-110429 |
| AV-LIDAR | Apple, Capturing depth using the LiDAR camera | https://developer.apple.com/documentation/avfoundation/capturing-depth-using-the-lidar-camera |
| AV-LIDAR-DOC | Apple, `builtInLiDARDepthCamera` | https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtinlidardepthcamera |
| AV-INTR | Apple, `isCameraIntrinsicMatrixDeliveryEnabled` | https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled |
| AV-LUT | Apple, `AVCameraCalibrationData.lensDistortionLookupTable` | https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/lensdistortionlookuptable |
| AV-CALDEL | Apple, `AVCapturePhotoOutput.isCameraCalibrationDataDeliverySupported` (needs GDC off) | https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iscameracalibrationdatadeliverysupported |
| AV-GDC | Apple, `AVCaptureDevice.isGeometricDistortionCorrectionEnabled` (default true) | https://developer.apple.com/documentation/avfoundation/avcapturedevice/isgeometricdistortioncorrectionenabled |
| AV-STAB | Apple, `AVCaptureConnection.preferredVideoStabilizationMode` (defaults to off) | https://developer.apple.com/documentation/avfoundation/avcaptureconnection/preferredvideostabilizationmode |
| AV-FOCUS | Apple, `setFocusModeLocked(lensPosition:completionHandler:)` | https://developer.apple.com/documentation/avfoundation/avcapturedevice/setfocusmodelocked(lensposition:completionhandler:) |
| FORUM-SYNC | Apple Dev Forums 742501, synced depth/video not received | https://developer.apple.com/forums/thread/742501 |
| ARKIT-DEPTH | Apple, `ARDepthData` | https://developer.apple.com/documentation/arkit/ardepthdata |
| ARKIT-FS | Apple, `supportsFrameSemantics(_:)` | https://developer.apple.com/documentation/arkit/arconfiguration/supportsframesemantics(_:) |
| MED-5M | Medium, ARKit 911 LiDAR (5 m, secondary) | https://medium.com/@arkit/arkit-911-scene-reconstruction-with-a-lidar-scanner-57ff0a8b247e |
| VN-TRAJ | Apple, Identifying trajectories in video | https://developer.apple.com/documentation/vision/identifying-trajectories-in-video |
| VN | Apple, `VNDetectHumanBodyPoseRequest` | https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest |
| VSEG | Apple, `VNGeneratePersonSegmentationRequest` | https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest |
| PIX2P | pix2pockets project page; arXiv 2504.12045 (paper CC BY 4.0) | https://pix2pockets.compute.dtu.dk/ ; https://arxiv.org/abs/2504.12045 |
| PIX2P-RF | Roboflow bachelorthesis "8-Ball Pool" / "Segmentation" | https://universe.roboflow.com/bachelorthesis/8-ball-pool-l530o ; https://universe.roboflow.com/bachelorthesis/8-ball-pool-segmentation |
| UL-LIC | Ultralytics licensing page and request-license page (AGPL covers trained models; Enterprise by quote) | https://www.ultralytics.com/license ; https://www.ultralytics.com/request-license |
| UL-COREML | Ultralytics docs, CoreML integration (YOLO26n 3.7 ms CPU+ANE on iPhone 17 Pro, iOS 27.0.1; sustained-use caveat) | https://docs.ultralytics.com/integrations/coreml/ |
| YOLO26 | Jocher et al., "Ultralytics YOLO26: Unified Real-Time End-to-End Vision Models", arXiv 2606.03748 | https://arxiv.org/abs/2606.03748 |
| RF-DETR | Roboflow RF-DETR (Apache 2.0) | https://blog.roboflow.com/rf-detr-is-free-to-use-commercially/ |
| RF-DETR-LIC | Roboflow RF-DETR licensing (PML 1.0 sizes) | https://roboflow.com/model-licenses/rf-detr |
| YOLOX-RF | Roboflow playground, YOLOX | https://playground.roboflow.com/models/megvii/yolox |
| YOLOX-HF | Hugging Face, YOLOX-S Core AI (~22 ms iPhone 17 Pro) | https://huggingface.co/coreai-community/YOLOX-CoreAI |
| MIT-YOLO | MultimediaTechLab/YOLO (MIT) | https://awesome.ecosyste.ms/projects/github.com%2FMultimediaTechLab%2FYOLO |
| DFINE-RF | Roboflow, D-FINE | https://playground.roboflow.com/models/compare/d-fine-vs-yolov9 |
| CREATEML | Apple Tech Talk 10155 | https://developer.apple.com/videos/play/tech-talks/10155/ |
| CT-OPT | coremltools optimization guides | https://apple.github.io/coremltools/docs-guides/source/opt-workflow.html |
| CT-COMM | Community coreml-optimizer guide (unverified) | https://smithery.ai/skills/ckorhonen/coreml-optimizer |
| CML-DOC | Apple, Core ML framework docs (iOS 11+; only `MLModelCollection` deprecated; links Core AI) | https://developer.apple.com/documentation/coreml |
| CML-MLMODEL | Apple, `MLModel` (no deprecation) | https://developer.apple.com/documentation/coreml/mlmodel |
| COREAI-DOC | Apple, Core AI framework (iOS 27.0+, CPU/GPU/Neural Engine, `.aimodel`) | https://developer.apple.com/documentation/coreai |
| WWDC26-324 | WWDC26 "Meet Core AI" | https://developer.apple.com/videos/play/wwdc2026/324/ |
| WWDC26-326 | WWDC26 "Integrate on-device AI models into your app using Core AI" (`coreai-build` AOT) | https://developer.apple.com/videos/play/wwdc2026/326/ |
| RF-SEARCH | Roboflow Universe pool datasets | https://universe.roboflow.com/main-cpmku/pool-ball-detection-jhi6w ; https://universe.roboflow.com/bastogne-billiards/pool-balls-uibmm ; https://universe.roboflow.com/pool-tracking/pool-balls-rpx9d ; https://universe.roboflow.com/ben-gann-lscqy/pool-balls-qlnkb ; https://universe.roboflow.com/cuebit/billiards-ball-detection-lmzkl ; https://universe.roboflow.com/cueball/detect-ball-on-pool-table ; https://universe.roboflow.com/pool-ball-detection-nadnq/pool-ball-detection-lm32j |
| RF-SEARCH2 | Roboflow Universe (skylep, adam-shortland, billiards-project) | https://universe.roboflow.com/skylep/8-ball-pool-mxyjm ; https://universe.roboflow.com/adam-shortland-wsc62/billiard-balls-yudfl ; https://universe.roboflow.com/billiards-project/nine-balls-segmentation-9a82w |
| BLENDER-LIC | Blender license | https://www.blender.org/about/license/ |
| BLENDERPROC | BlenderProc LICENSE (GPL-3.0) | https://github.com/DLR-RM/BlenderProc/blob/main/LICENSE |
| POOLTOOL | ekiefl/pooltool (Apache-2.0) | https://github.com/ekiefl/pooltool |
| RULES-NOTES | Internal: `docs/research/rules-notes.md` (WPA 1.8, 2.2, 2.6, 2.7, 3.6, 5.3(c), 5.4, Reg 26, with WPA PDF links) | docs/research/rules-notes.md |

## Reviewer notes

All 20 issues were accepted and fixed. These are partial disagreements and clarifications:
- **Stabilization (BLOCKER 2).** Apple's docs say `preferredVideoStabilizationMode` **defaults to `.off`** [AV-STAB], so default modes do not warp frames. The requirement is still made explicit, with an assertion on `activeVideoStabilizationMode`. OIS can't be turned off through any API I found (unverified), so it's handled by per-frame `K` and the rail residual instead.
- **"LiDAR and ARKit fail together" (MAJOR 6).** Accepted for a still tripod. The ball-size estimator and the new rack-spacing estimator are the independent sources.
- **Detector at 60 Hz (MAJOR 8).** Accepted as the design, but at the input size that undistorted-image detection needs (§4.3), 8 ms is not proven. The 30 Hz + window-crop fallback is kept and must earn its place with measured recall, not by assertion.
- **Shot-end target.** "±5 frames" was replaced with "≤ 1.0 s after true rest", because the noise-derived rest test (§5.2) can't meet ±5 frames at σ = 3 mm.
- **Latency.** The ≤ 50 ms target became an est. ≤ 70 ms p95 with its derivation, to be measured. Drawing the preview from the same buffer makes the sync of lines and image independent of latency.
