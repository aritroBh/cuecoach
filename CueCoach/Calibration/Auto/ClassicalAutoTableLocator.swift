import Foundation
import Geometry
import simd
import Synchronization

/// Classical-vision AutoTableLocator: cloth segmentation → sub-pixel rail lines → lift onto the
/// (LiDAR-refined) table plane → 2:1 rectangle fit + preset snap → world-space multi-frame fusion.
/// An optional `TableKeypointProvider` (Core ML pose model) adds pocket/corner constraints and
/// is the fallback when segmentation fails.
final class ClassicalAutoTableLocator: AutoTableLocator {
    struct Config: Sendable {
        var profile = AutoTableProfile()
        var fusion = AutoFusionConfig()
        /// Coarse segmentation grid width (px).
        var coarseWidth = 240
        /// Frames whose own reprojection RMS exceeds this are dropped (px).
        var maxFrameRMS = 2.5
        /// One keypoint weighs as much as this many edge samples.
        var keypointWeight = 15.0
        /// A LiDAR cloth level further than this from the ARKit/depth plane is not believed (m).
        var maxClothOffset = 0.03
        /// Measure the rail-cap height above the cloth with LiDAR (else the profile value is used as is).
        var measureRailTopHeight = true
        /// A LiDAR rail-cap height is believed only within this distance of the profile default (m).
        /// Kept tight until device evidence exists: smoothed real depth biases the band toward the cloth.
        var maxRailHeightDeviation = 0.008
        /// Views flatter than this (camera elevation over the table centre) are not measured: lifted rails
        /// slide along grazing rays, so plane/rail-height errors become large size errors.
        var minViewElevation = 12 * Double.pi / 180
        /// Keypoint-only frames whose own fit explains the keypoints worse than this are dropped (px; model
        /// keypoints are noisier than sub-pixel rail edges).
        var maxKeypointFrameRMS = 10.0
        /// Cloth segmentation counts only pixels LiDAR positively puts within this of the cloth plane (m).
        /// (0.035 — below the rail caps — was tried: no matrix gain, and it broke partial views.)
        var segmentationTolerance = 0.12
    }

    /// Per-frame detector state. Owned by the `processing` lock, which serialises `process()` calls, so
    /// concurrent callers queue instead of overwriting each other's cloth levels, rail heights and model.
    private struct Work {
        var fused: AutoTablePose?
        var model: AutoClothModel?
        /// Recent LiDAR cloth levels (world height along the plane normal).
        var clothLevels: [Double] = []
        /// Recent LiDAR rail-cap heights above the cloth.
        var railHeights: [Double] = []
        var rng = AutoRandom()
        /// `State.epoch` this work belongs to; a reset since then discards it.
        var epoch = 0
    }

    private struct State {
        var fusion: AutoTableFusion
        var latest: AutoTableEstimate?
        var lastTimestamp: Double?
        /// Bumped by `reset()`. A detection that started before a reset is dropped, not fused.
        var epoch = 0
    }

    /// Test/debug hook: the raw cloth mask, the table component and the cloth model of each full search.
    /// Never set in production.
    static let debugMaskSink = Mutex<(@Sendable (AutoMask, AutoMask, AutoClothModel) -> Void)?>(nil)

    let config: Config
    private let keypointProvider: (any TableKeypointProvider)?
    /// Short critical sections only: readers, flips and resets never wait for a detection.
    private let state: Mutex<State>
    /// Held for a whole `process()` call (lock order: processing → state).
    private let processing = Mutex(Work())

    init(config: Config = Config(), keypoints: (any TableKeypointProvider)? = nil) {
        self.config = config
        keypointProvider = keypoints
        state = Mutex(State(fusion: AutoTableFusion(config: config.fusion)))
    }

    var latest: AutoTableEstimate? { state.withLock { $0.latest } }

    /// Detector state counters (tests).
    var debugWorkCounts: (clothLevels: Int, railHeights: Int) {
        let epoch = state.withLock { $0.epoch }
        return processing.withLock { $0.epoch == epoch ? ($0.clothLevels.count, $0.railHeights.count) : (0, 0) }
    }

    func flipHeadFoot() {
        state.withLock { s in
            s.fusion.flip()
            if var l = s.latest { l.pose = s.fusion.fused; s.latest = l }
        }
    }

    func reset() {
        state.withLock { s in s = State(fusion: AutoTableFusion(config: config.fusion), epoch: s.epoch &+ 1) }
    }

    func process(_ frame: AutoTableFrame) -> AutoTableEstimate {
        processing.withLock { stored in process(frame, stored: &stored) }
    }

    private func process(_ frame: AutoTableFrame, stored: inout Work) -> AutoTableEstimate {
        let t0 = Date()
        // 1. Under the state lock: skip unusable frames, note the epoch and the fused pose.
        enum Gate { case skip(AutoTableEstimate), run(epoch: Int, fused: AutoTablePose?) }
        let gate: Gate = state.withLock { s in
            var reason: String?
            if frame.tracking != .normal { reason = "tracking" }
            else if s.lastTimestamp == frame.timestamp { reason = "duplicate frame" }
            if let reason {
                var diag = AutoFrameDiagnostics()
                diag.rejection = reason
                var est = s.latest ?? AutoTableEstimate(state: .searching, pose: nil, confidence: 0, cornerSpread: .infinity,
                                                         fusedReprojectionRMS: nil, generation: s.fusion.generation, frame: diag)
                est.frame = diag
                s.latest = est
                return .skip(est)
            }
            s.lastTimestamp = frame.timestamp
            return .run(epoch: s.epoch, fused: s.fusion.fused)
        }
        let epoch: Int
        switch gate {
        case .skip(let e): return e
        case .run(let e, let fused):
            epoch = e
            if stored.epoch != e { stored = Work(); stored.epoch = e }  // reset() since the last frame
            stored.fused = fused
        }
        var work = stored

        // 2. Detection (and the keypoint model) without the state lock: readers and flips never wait for it.
        var diag = AutoFrameDiagnostics()
        let camera = AutoCamera(intrinsics: frame.intrinsics, cameraToWorld: frame.cameraToWorld)
        let det = detect(frame, camera: camera, state: &work, diag: &diag)
        if let m = det?.measurement {
            diag.measuredLength = m.measuredLength; diag.measuredWidth = m.measuredWidth; diag.snappedSize = m.snapped
        }
        work.fused = nil

        // 3. Under the state lock: fuse and validate, unless a reset happened meanwhile (then this frame
        //    belongs to the forgotten table and is dropped, and so is its detector state).
        let result: AutoTableEstimate? = state.withLock { s in
            guard s.epoch == epoch else { return nil }
            s.fusion.add(det?.measurement)
            let fused = s.fusion.fused
            var fusedRMS: Double?
            if let f = fused, let d = det {
                if !d.edgePoints.isEmpty {
                    fusedRMS = Self.reprojectionRMS(d.edgePoints, pose: f, plane: d.plane, camera: camera, profile: d.profile)
                } else if !d.keypoints.isEmpty {
                    let r = Self.keypointRMS(d.keypoints, pose: f, camera: camera, profile: d.profile)
                    fusedRMS = r.isFinite ? r : nil
                }
                diag.pocketScores = pocketScores(frame.image, camera: camera, pose: f, profile: d.profile)
            }
            let lockState: AutoLockState
            if fused == nil { lockState = .searching } else if s.fusion.locked { lockState = .locked }
            else { lockState = .converging(progress: s.fusion.progress) }
            diag.processingSeconds = Date().timeIntervalSince(t0)
            let conf = confidence(state: lockState, progress: s.fusion.progress, rms: fusedRMS ?? diag.reprojectionRMS,
                                  pockets: diag.pocketScores)
            let est = AutoTableEstimate(state: lockState, pose: fused, confidence: conf, cornerSpread: s.fusion.spread,
                                        fusedReprojectionRMS: fusedRMS, generation: s.fusion.generation, frame: diag)
            s.latest = est
            return est
        }
        guard let result else {
            var d = AutoFrameDiagnostics()
            d.rejection = "reset"
            return AutoTableEstimate(state: .searching, pose: nil, confidence: 0, cornerSpread: .infinity,
                                     fusedReprojectionRMS: nil, generation: 0, frame: d)
        }
        stored = work
        return result
    }

    // MARK: - Per-frame detection

    private struct Detection {
        var measurement: AutoTableMeasurement
        var edgePoints: [AutoP2]
        /// Keypoint-only path: the keypoints the measurement came from (validation against the fused pose).
        var keypoints: [AutoTableKeypoint] = []
        var plane: AutoTablePlane
        /// Profile used for this frame (rail-cap height possibly measured by LiDAR).
        var profile: AutoTableProfile
    }

    /// The configured profile with the LiDAR-measured rail-cap height when there is one.
    private func effectiveProfile(_ s: Work) -> AutoTableProfile {
        var p = config.profile
        if !s.railHeights.isEmpty { p.railTopHeight = autoMedian(s.railHeights) }
        return p
    }

    private func detect(_ f: AutoTableFrame, camera: AutoCamera, state s: inout Work,
                        diag: inout AutoFrameDiagnostics) -> Detection? {
        var prof = effectiveProfile(s)
        let img = f.image
        // 1. Table plane: ARKit hint (or a LiDAR-only estimate), corrected by the LiDAR cloth level.
        guard var plane = basePlane(f, camera: camera) else { diag.rejection = "no plane"; return nil }
        let hintLevel = simd_dot(plane.origin, plane.normal)
        if !s.clothLevels.isEmpty {
            let level = autoMedian(s.clothLevels)
            plane.origin += plane.normal * (level - simd_dot(plane.origin, plane.normal))
        }

        // 2. Rail lines: track from the fused pose when possible, else full search.
        var edges: [AutoRailEdge]?
        if let pose = s.fused, let model = s.model {
            let c = prof.cushionWidth, L = pose.spec.length, W = pose.spec.width
            let q = [AutoP2(-c, -c), AutoP2(-c, W + c), AutoP2(L + c, W + c), AutoP2(L + c, -c)]
                .compactMap { camera.project(pose.world(Vec2($0.x, $0.y), height: prof.railTopHeight)) }
            if q.count == 4, AutoPolygon.area(q) > 400 {
                edges = AutoRailDetector.refine(img, model: model, corners: q, radius: 12, rng: &s.rng)
                if edges != nil { diag.path = .tracked }
            }
        }
        var seed: PartialSeed?
        if edges == nil {
            edges = fullSearch(f, camera: camera, plane: plane, profile: prof, state: &s, diag: &diag, partial: &seed)
            if edges != nil { diag.path = .full }
        }
        let keypoints = keypointProvider?.keypoints(in: img, intrinsics: f.intrinsics) ?? []

        if edges == nil, let seed {
            // Part of the table is out of view (or its outline is broken): fit the visible rails.
            var pd = diag
            pd.rejection = nil
            if let det = partialDetect(f, seed: seed, camera: camera, plane: plane, hintLevel: hintLevel, profile: prof,
                                       state: &s, diag: &pd) {
                pd.path = .full
                diag = pd
                return det
            }
            if let r = pd.rejection { diag.rejection = "\(diag.rejection ?? "partial") (\(r))" }
        }

        if edges == nil {
            // Keypoint-only fallback (LiDAR level from the keypoint quad).
            let kq = keypoints.filter { $0.kind == .noseCorner && $0.confidence >= 0.3 }.map(\.pixel)
            if kq.count == 4 {
                let cen = kq.reduce(AutoP2.zero, +) / 4
                let ordered = kq.sorted { atan2($0.y - cen.y, $0.x - cen.x) < atan2($1.y - cen.y, $1.x - cen.x) }
                refineLevel(f, camera: camera, quad: ordered, plane: &plane, hintLevel: hintLevel, state: &s, diag: &diag)
            }
            guard let det = keypointOnly(keypoints, camera: camera, plane: plane, profile: prof, diag: &diag) else {
                if diag.rejection == nil { diag.rejection = "no rails" }
                return nil
            }
            // Same safety gates as the rail paths: plausible fit, not a grazing view.
            guard diag.reprojectionRMS < config.maxKeypointFrameRMS else { diag.rejection = "keypoint reprojection"; return nil }
            guard viewElevation(camera, center: det.measurement.center, up: plane.normal) >= config.minViewElevation else {
                diag.rejection = "view too shallow"; return nil
            }
            diag.path = .keypointsOnly
            return det
        }
        let rails = edges!
        diag.railLines = rails.map(\.line.abc)
        let attempted = rails.reduce(0) { $0 + $1.attempted }, used = rails.reduce(0) { $0 + $1.points.count }
        diag.inlierFraction = attempted > 0 ? Double(used) / Double(attempted) : 0
        guard let imgCorners = AutoRailDetector.corners(rails.map(\.line)) else { diag.rejection = "parallel rails"; return nil }
        diag.outerCorners = imgCorners

        // 3. LiDAR cloth level from the bed interior, then the rail-cap height above it.
        refineLevel(f, camera: camera, quad: imgCorners, plane: &plane, hintLevel: hintLevel, state: &s, diag: &diag)
        if config.measureRailTopHeight, let d = f.depth {
            let Q = imgCorners.compactMap { plane.lift($0, camera: camera, height: prof.railTopHeight) }
            if Q.count == 4, let r = AutoPlaneRefiner.railTopHeight(depth: d, camera: camera, imageWidth: img.width,
                                                                     imageHeight: img.height, plane: plane, feltCorners: Q),
               abs(r.height - config.profile.railTopHeight) <= config.maxRailHeightDeviation {
                s.railHeights.append(r.height)
                if s.railHeights.count > 15 { s.railHeights.removeFirst() }
                prof = effectiveProfile(s)
            }
        }

        diag.railTopHeight = prof.railTopHeight

        // 4. Lift to the plane and fit the rectangle.
        guard var fit = fitRectangle(rails: rails, corners: imgCorners, keypoints: keypoints, camera: camera,
                                     plane: plane, profile: prof, diag: &diag) else { return nil }
        func pose(_ f: RectFit) -> AutoTablePose {
            let ax = plane.e1 * f.rect.u.x + plane.e2 * f.rect.u.y
            return AutoTableFusion.pose(center: plane.to3D(f.rect.center), axis: ax, up: plane.normal, spec: f.spec,
                                        snapped: f.snapped, measured: (f.measuredL, f.measuredW), headToFoot: ax)!
        }
        var allPts = rails.flatMap(\.points)
        var pose0 = pose(fit)
        diag.reprojectionRMS = Self.reprojectionRMS(allPts, pose: pose0, plane: plane, camera: camera, profile: prof)
        if diag.reprojectionRMS >= config.maxFrameRMS {
            // One rail edge confused (a lamp highlight on the cushion, a shadow, an arm) while the other three agree:
            // refit without it, sizing from the other axis at 2:1. Never more than one rail.
            let perRail = rails.map { Self.reprojectionRMS($0.points, pose: pose0, plane: plane, camera: camera, profile: prof) }
            // Never for a table the frame may crop (the partial-view rule would be bypassed): all four corners in view.
            let inFrame = imgCorners.allSatisfy { $0.x > 8 && $0.y > 8 && $0.x < Double(img.width - 9) && $0.y < Double(img.height - 9) }
            guard inFrame, let k = perRail.indices.max(by: { perRail[$0] < perRail[$1] }), perRail[k] >= config.maxFrameRMS,
                  perRail.indices.filter({ $0 != k }).allSatisfy({ perRail[$0] < config.maxFrameRMS }),
                  let f2 = fitRectangle(rails: rails, corners: imgCorners, keypoints: keypoints, camera: camera,
                                        plane: plane, profile: prof, exclude: k, diag: &diag) else {
                diag.rejection = diag.rejection ?? "reprojection"; return nil
            }
            // The size now comes from the one axis whose two rails remain; it must be the well-conditioned one
            // (across the image, not along the view rays — VirtualTable light-lamp seed 6 sized a 7 ft as 8 ft from
            // a width measured 13 % long along the rays).
            let liftedK = rails[k].points.compactMap { plane.lift($0, camera: camera, height: prof.railTopHeight) }
            let view2 = plane.to2D(plane.to3D(f2.rect.center) + (plane.to3D(f2.rect.center) - camera.position)) - f2.rect.center
            guard let lk = AutoLine.fit(liftedK), simd_length(view2) > 1e-6 else { diag.rejection = "reprojection"; return nil }
            let sizingAxis = abs(simd_dot(lk.direction, f2.rect.u)) > 0.7 ? f2.rect.u : f2.rect.v
            guard abs(simd_dot(sizingAxis, simd_normalize(view2))) <= 0.64 else { diag.rejection = "reprojection"; return nil }
            let kept = rails.indices.filter { $0 != k }.flatMap { rails[$0].points }
            let p2 = pose(f2)
            let rms2 = Self.reprojectionRMS(kept, pose: p2, plane: plane, camera: camera, profile: prof)
            guard rms2 < config.maxFrameRMS else { diag.rejection = "reprojection"; return nil }
            fit = f2; pose0 = p2; allPts = kept; diag.reprojectionRMS = rms2; diag.droppedRail = k
        }
        guard viewElevation(camera, center: pose0.center, up: plane.normal) >= config.minViewElevation else {
            diag.rejection = "view too shallow"; return nil
        }
        let m = AutoTableMeasurement(center: pose0.center, axis: pose0.xAxis, up: plane.normal,
                                     measuredLength: fit.measuredL, measuredWidth: fit.measuredW, snapped: fit.snapped,
                                     cameraPosition: camera.position)
        return Detection(measurement: m, edgePoints: allPts, plane: plane, profile: prof)
    }

    private func refineLevel(_ f: AutoTableFrame, camera: AutoCamera, quad: [AutoP2], plane: inout AutoTablePlane,
                             hintLevel: Double, state s: inout Work, diag: inout AutoFrameDiagnostics) {
        guard let d = f.depth, quad.count >= 3 else { return }
        let cen = quad.reduce(AutoP2.zero, +) / Double(quad.count)
        let bed = quad.map { cen + ($0 - cen) * 0.7 }
        guard let r = AutoPlaneRefiner.clothOffset(depth: d, camera: camera, imageWidth: f.image.width,
                                                   imageHeight: f.image.height, bed: bed, plane: plane) else { return }
        let level = simd_dot(plane.origin, plane.normal) + r.offset
        // Something over the bed (a body, an arm) is not the cloth: stay near the ARKit/depth plane.
        guard abs(level - hintLevel) <= config.maxClothOffset else { return }
        plane.origin += plane.normal * r.offset
        s.clothLevels.append(level)
        if s.clothLevels.count > 15 { s.clothLevels.removeFirst() }
        let m = autoMedian(s.clothLevels)
        plane.origin += plane.normal * (m - level)
        diag.lidarClothHeight = m
    }

    private func basePlane(_ f: AutoTableFrame, camera: AutoCamera) -> AutoTablePlane? {
        if let h = f.plane {
            // ARKit often anchors the floor before a low-texture cloth: if LiDAR sees a clear horizontal level at
            // pool-table height above the hinted plane, that level is the table.
            // Only a floor-like hint (≥ 1 m under the camera) is replaced, and only by the dominant level in the
            // central part of the view (where the user points at the table), not any table-height surface in frame.
            if let d = f.depth, abs(h.normal.y) > 0.95, camera.position.y - h.point.y >= 1.0,
               let level = AutoPlaneRefiner.horizontalLevels(depth: d, camera: camera, imageWidth: f.image.width,
                                                             imageHeight: f.image.height, central: true)
                   .first(where: { (0.55...1.1).contains($0.level - h.point.y) && camera.position.y - $0.level > 0.2 }) {
                // Largest-share level in range: the bed, not the narrower rail caps 4.5 cm above it.
                return AutoTablePlane(origin: SIMD3(h.point.x, level.level, h.point.z), normal: SIMD3(0, 1, 0))
            }
            return AutoTablePlane(origin: h.point, normal: h.normal)
        }
        guard let d = f.depth else { return nil }
        // No ARKit plane yet: the dominant horizontal level in the central depth region.
        var ys: [Double] = []
        let sx = Double(f.image.width) / Double(d.width), sy = Double(f.image.height) / Double(d.height)
        for v in Swift.stride(from: d.height / 3, to: 2 * d.height / 3, by: 4) {
            for u in Swift.stride(from: d.width / 3, to: 2 * d.width / 3, by: 4) {
                let z = Double(d.depth[v * d.width + u])
                guard z > 0.1 else { continue }
                ys.append(camera.unproject(AutoP2((Double(u) + 0.5) * sx - 0.5, (Double(v) + 0.5) * sy - 0.5), depth: z).y)
            }
        }
        guard ys.count > 20 else { return nil }
        let p = camera.position
        return AutoTablePlane(origin: SIMD3(p.x, autoMedian(ys), p.z), normal: SIMD3(0, 1, 0))
    }

    /// What a failed full search hands the partial fitter.
    private struct PartialSeed {
        var mask: AutoMask
        var model: AutoClothModel
        var boundary: [AutoP2]
        var stride: Int
    }

    /// Expected on-screen area (working px²) of the smallest preset's outer felt at the plane distance,
    /// so the size gates follow the view distance (2–3 m views are small but valid).
    private func expectedTableArea(_ f: AutoTableFrame, camera: AutoCamera, plane: AutoTablePlane) -> Double? {
        let c = AutoP2(f.intrinsics.cx, f.intrinsics.cy)
        guard let hit = camera.lift(c, point: plane.origin, normal: plane.normal) else { return nil }
        let d = simd_distance(hit, camera.position)
        let cosv = abs(simd_dot(simd_normalize(camera.position - hit), plane.normal))
        let spec = TableSpec(size: .sevenFoot), cw = config.profile.cushionWidth
        let area = (spec.length + 2 * cw) * (spec.width + 2 * cw)
        return area * f.intrinsics.fx * f.intrinsics.fy * max(cosv, 0.2) / (d * d)
    }

    private func fullSearch(_ f: AutoTableFrame, camera: AutoCamera, plane: AutoTablePlane, profile: AutoTableProfile,
                            state s: inout Work, diag: inout AutoFrameDiagnostics, partial: inout PartialSeed?) -> [AutoRailEdge]? {
        let img = f.image
        let stride = max(2, img.width / config.coarseWidth)
        var gate: [UInt8]?
        var learnGate: [UInt8]?
        if let d = f.depth {
            // Segment only where LiDAR positively sees table height (dim rooms: a dark, noisy floor or wall with
            // no depth confidence otherwise matches a dark cloth model).
            gate = AutoPlaneRefiner.gate(depth: d, camera: camera, imageWidth: img.width, imageHeight: img.height,
                                         plane: plane, tolerance: config.segmentationTolerance, grow: 3, trustUnknown: false)
            learnGate = AutoPlaneRefiner.gate(depth: d, camera: camera, imageWidth: img.width, imageHeight: img.height,
                                              plane: plane, tolerance: 0.025, trustUnknown: false)
        }
        let dw = f.depth?.width ?? 0, dh = f.depth?.height ?? 0
        // Learn where LiDAR says "cloth height" anywhere in the frame; it must be a real bed-sized area
        // (an arm over the bed leaves only cushion strips), else fall back to the image centre.
        let accept: ((Int, Int) -> Bool)? = learnGate.map { g in
            { x, y in g[(y * dh / img.height) * dw + x * dw / img.width] != 0 }
        }
        guard let model = AutoClothModel.learn(img, stride: stride, accept: accept, allowNeutral: true, minSamples: 300)
                ?? AutoClothModel.learn(img, stride: stride) ?? s.model else {
            diag.rejection = "no cloth colour"; return nil
        }
        // A neutral model matches any grey surface, so it only counts pixels LiDAR positively puts at table height.
        if model.neutral, let d = f.depth {
            gate = AutoPlaneRefiner.gate(depth: d, camera: camera, imageWidth: img.width, imageHeight: img.height,
                                         plane: plane, tolerance: config.segmentationTolerance, grow: 3, trustUnknown: false)
        }
        let raw = AutoClothSegmenter.mask(img, model: model, stride: stride, gate: gate, gateWidth: dw, gateHeight: dh)
        let opened = AutoClothSegmenter.open(raw)
        // Occluders split the cloth: merge large neighbouring pieces (gap ≤ ~8 % of the frame width).
        let (comp, size) = AutoClothSegmenter.tableComponent(opened, maxGap: max(4, opened.width / 12), minFraction: 0.15)
        if let sink = Self.debugMaskSink.withLock({ $0 }) { sink(raw, comp, model) }
        let expected = expectedTableArea(f, camera: camera, plane: plane)
        let minArea = min(Double(img.width * img.height) / 40, 0.3 * (expected ?? .infinity))
        let gridCell = Double(stride * stride)
        guard Double(size) * gridCell > max(minArea, 400 * gridCell) else { diag.rejection = "cloth too small"; return nil }
        let (pts, border) = AutoClothSegmenter.boundary(comp)
        // A component hugging the frame is cut off: the partial fitter takes over.
        guard border < (comp.width + comp.height) / 6 else {
            diag.rejection = "cloth touches frame"
            partial = PartialSeed(mask: comp, model: model, boundary: pts, stride: stride)
            return nil
        }
        let hr = profile.railTopHeight
        let isTableQuad: ([AutoP2]) -> Bool = { q in
            let Q = q.compactMap { plane.lift($0, camera: camera, height: hr) }
            guard Q.count == 4 else { return false }
            let sides = (0..<4).map { Q[($0 + 1) % 4] - Q[$0] }
            let len = sides.map { simd_length($0) }
            guard len.allSatisfy({ $0 > 0.3 }) else { return false }
            for i in 0..<4 where abs(simd_dot(sides[i], sides[(i + 1) % 4])) / (len[i] * len[(i + 1) % 4]) > 0.12 { return false }
            let a = (len[0] + len[2]) / 2, b = (len[1] + len[3]) / 2
            let ratio = max(a, b) / min(a, b)
            return Self.plausibleAspect(ratio) && abs(len[0] - len[2]) / a < 0.15 && abs(len[1] - len[3]) / b < 0.15
        }
        guard let coarse = AutoRailDetector.coarseLines(boundary: pts, stride: stride, rng: &s.rng, accept: isTableQuad),
              let q = AutoRailDetector.corners(coarse), AutoPolygon.area(q) > minArea,
              q.allSatisfy({ abs($0.x - Double(img.width) / 2) < Double(img.width) && abs($0.y - Double(img.height) / 2) < Double(img.height) })
        else {
            diag.rejection = "no quad"
            partial = PartialSeed(mask: comp, model: model, boundary: pts, stride: stride)
            return nil
        }
        guard let edges = AutoRailDetector.refine(img, model: model, corners: q, radius: max(6, 2.5 * Double(stride)),
                                                  rng: &s.rng) else {
            // Typically one "rail" of the quad is the frame cut: try the visible rails alone.
            diag.rejection = "edge refine"
            partial = PartialSeed(mask: comp, model: model, boundary: pts, stride: stride)
            return nil
        }
        s.model = model
        return edges
    }

    private struct RectFit {
        var rect: AutoRect
        var spec: TableSpec
        var snapped: TableSize?
        var measuredL: Double
        var measuredW: Double
    }

    /// `exclude`: a rail whose edge is not trusted (its samples are left out and the size comes from the other
    /// axis at 2:1).
    private func fitRectangle(rails: [AutoRailEdge], corners q: [AutoP2], keypoints: [AutoTableKeypoint],
                              camera: AutoCamera, plane: AutoTablePlane, profile prof: AutoTableProfile,
                              exclude: Int? = nil, diag: inout AutoFrameDiagnostics) -> RectFit? {
        let hr = prof.railTopHeight, c = prof.cushionWidth
        let Q = q.compactMap { plane.lift($0, camera: camera, height: hr) }
        guard Q.count == 4 else { diag.rejection = "corner above horizon"; return nil }
        let center = Q.reduce(AutoP2.zero, +) / 4
        let len = (0..<4).map { simd_length(Q[($0 + 1) % 4] - Q[$0]) }
        let firstShort = len[0] + len[2] < len[1] + len[3]  // rails 0 & 2 are the short (head/foot) rails?
        let shortRail = firstShort ? 0 : 1
        func outward(_ i: Int) -> AutoP2 {
            let d = Q[(i + 1) % 4] - Q[i]
            var n = simd_normalize(AutoP2(-d.y, d.x))
            if simd_dot(n, (Q[i] + Q[(i + 1) % 4]) / 2 - center) < 0 { n = -n }
            return n
        }
        let n0 = outward(shortRail)
        let theta = atan2(n0.y, n0.x)
        var side = [Int](repeating: 0, count: 4)
        for i in 0..<4 {
            let n = outward(i)
            let d = autoWrapPi(atan2(n.y, n.x) - theta)
            side[i] = ((Int((d / (.pi / 2)).rounded()) % 4) + 4) % 4
        }
        guard Set(side).count == 4 else { diag.rejection = "not a rectangle"; return nil }
        let longLen = firstShort ? (len[1] + len[3]) / 2 : (len[0] + len[2]) / 2
        let shortLen = firstShort ? (len[0] + len[2]) / 2 : (len[1] + len[3]) / 2
        var rect = AutoRect(center: center, theta: theta, a: longLen / 2 - c, b: shortLen / 2 - c)
        guard rect.a > 0.4, rect.b > 0.2 else { diag.rejection = "too small"; return nil }

        var samples: [AutoRectFitter.EdgeSample] = []
        for (i, r) in rails.enumerated() where i != exclude {
            for p in r.points {
                if let w = plane.lift(p, camera: camera, height: hr) {
                    samples.append(.init(p: w, side: side[i], offset: c))
                }
            }
        }
        guard let free = AutoRectFitter.fit(rect, edges: samples, mode: exclude == nil ? .free : .aspect) else {
            diag.rejection = "fit"; return nil
        }
        rect = free.rect
        let kp = keypointSamples(keypoints, rect: rect, camera: camera, plane: plane, profile: prof)
        diag.keypointsUsed = kp.count
        if !kp.isEmpty, let f2 = AutoRectFitter.fit(rect, edges: samples, points: kp, mode: .free) { rect = f2.rect }
        let L = 2 * rect.a, W = 2 * rect.b
        diag.measuredLength = L; diag.measuredWidth = W
        let verdict = AutoRectFitter.sizeVerdict(length: L, width: W)
        switch verdict {
        case .notTwoToOne: diag.rejection = "not 2:1"; return nil
        case .ambiguous: diag.rejection = "size ambiguous"; return nil
        case .implausibleSize: diag.rejection = "too small"; return nil
        case .measured where exclude != nil:
            // A three-rail fit has no independent size check: it must land on a preset.
            diag.rejection = "reprojection"; return nil
        case .preset, .measured: break
        }
        var spec = TableSpec(size: AutoRectFitter.snap(length: L, width: W).size)
        var snapped: TableSize?
        let final: AutoRect
        if case .preset(let size) = verdict {
            spec = TableSpec(size: size)
            guard let f = AutoRectFitter.fit(rect, edges: samples, points: kp, mode: .fixed(a: spec.length / 2, b: spec.width / 2))
            else { diag.rejection = "fit"; return nil }
            final = f.rect; snapped = size
        } else if let f = AutoRectFitter.fit(rect, edges: samples, points: kp, mode: .aspect) {
            final = f.rect
            spec.length = 2 * f.rect.a; spec.width = 2 * f.rect.b
        } else { diag.rejection = "fit"; return nil }
        return RectFit(rect: final, spec: spec, snapped: snapped, measuredL: L, measuredW: W)
    }

    /// Lifted keypoints matched to the nearest model point of `rect`.
    private func keypointSamples(_ kps: [AutoTableKeypoint], rect: AutoRect, camera: AutoCamera,
                                 plane: AutoTablePlane, profile prof: AutoTableProfile) -> [AutoRectFitter.PointSample] {
        var out: [AutoRectFitter.PointSample] = []
        for k in kps where k.confidence >= 0.3 {
            let h = prof.noseHeight
            let grow = k.kind == .cornerMouth ? -prof.cornerMouthInset : 0
            guard let p = plane.lift(k.pixel, camera: camera, height: h) else { continue }
            let cands: [(Double, Double)] = k.kind == .sideMouth ? [(0, 1), (0, -1)] : [(1, 1), (1, -1), (-1, 1), (-1, -1)]
            var best: (Double, Double)?, bd = Double.infinity
            for (sx, sy) in cands {
                let m = rect.center + rect.u * (sx * (rect.a + grow)) + rect.v * (sy * (rect.b + grow))
                let d = simd_distance(m, p)
                if d < bd { bd = d; best = (sx, sy) }
            }
            guard let b = best, bd < 0.15 else { continue }
            out.append(.init(p: p, sx: b.0, sy: b.1, grow: grow, weight: k.confidence * config.keypointWeight))
        }
        return out
    }

    private func keypointOnly(_ kps: [AutoTableKeypoint], camera: AutoCamera, plane: AutoTablePlane,
                              profile prof: AutoTableProfile, diag: inout AutoFrameDiagnostics) -> Detection? {
        let seen = kps.filter { $0.kind == .noseCorner && $0.confidence >= 0.3 }
        // Every nose corner must be in the frame: an extrapolated off-frame corner is a partial view, and
        // the keypoint path has no partial-view lock rule.
        let edge = 2.0
        guard seen.allSatisfy({ $0.pixel.x >= edge && $0.pixel.y >= edge && $0.pixel.x <= camera.k.width - 1 - edge
                                && $0.pixel.y <= camera.k.height - 1 - edge }) else {
            diag.rejection = "keypoint off frame"; return nil
        }
        let corners = seen.compactMap { plane.lift($0.pixel, camera: camera, height: prof.noseHeight) }
        guard corners.count == 4 else { return nil }
        let c = corners.reduce(AutoP2.zero, +) / 4
        // Major axis = direction of the longest centre-to-corner-pair sum: PCA of the 4 corners.
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in corners { let d = p - c; sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        var rect = AutoRect(center: c, theta: theta, a: 0, b: 0)
        rect.a = corners.map { abs(simd_dot($0 - c, rect.u)) }.reduce(0, +) / 4
        rect.b = corners.map { abs(simd_dot($0 - c, rect.v)) }.reduce(0, +) / 4
        guard rect.a > 0.4, rect.b > 0.2 else { return nil }
        // Nose-corner quad must be table-shaped (nose aspect ≈ 2; the outer-felt gate's 1.6–2.5 band).
        guard Self.plausibleAspect(rect.a / rect.b) else { diag.rejection = "keypoint aspect"; return nil }
        let kp = keypointSamples(kps, rect: rect, camera: camera, plane: plane, profile: prof)
        guard kp.count >= 4, let free = AutoRectFitter.fit(rect, edges: [], points: kp, mode: .free) else { return nil }
        diag.keypointsUsed = kp.count
        diag.measuredLength = 2 * free.rect.a; diag.measuredWidth = 2 * free.rect.b
        let snap = AutoRectFitter.snap(length: 2 * free.rect.a, width: 2 * free.rect.b)
        switch AutoRectFitter.sizeVerdict(length: 2 * free.rect.a, width: 2 * free.rect.b) {
        case .notTwoToOne: diag.rejection = "not 2:1"; return nil
        case .ambiguous: diag.rejection = "size ambiguous"; return nil
        case .measured, .implausibleSize: return nil
        case .preset: break
        }
        let spec = TableSpec(size: snap.size)
        guard let fixed = AutoRectFitter.fit(free.rect, edges: [], points: kp, mode: .fixed(a: spec.length / 2, b: spec.width / 2))
        else { return nil }
        let axis = plane.e1 * fixed.rect.u.x + plane.e2 * fixed.rect.u.y
        let m = AutoTableMeasurement(center: plane.to3D(fixed.rect.center), axis: axis, up: plane.normal,
                                     measuredLength: 2 * free.rect.a, measuredWidth: 2 * free.rect.b, snapped: snap.size,
                                     cameraPosition: camera.position)
        // No edge evidence: this frame's quality is how well its own fit explains the keypoints (pixels).
        let used = kps.filter { $0.confidence >= 0.3 }
        if let p = AutoTableFusion.pose(center: m.center, axis: axis, up: plane.normal, spec: spec, snapped: snap.size,
                                        measured: (m.measuredLength, m.measuredWidth), headToFoot: axis) {
            diag.reprojectionRMS = Self.keypointRMS(used, pose: p, camera: camera, profile: prof)
        }
        return Detection(measurement: m, edgePoints: [], keypoints: used, plane: plane, profile: prof)
    }

    /// RMS pixel distance of keypoints to the nearest re-projected model point of their kind on `pose`.
    static func keypointRMS(_ kps: [AutoTableKeypoint], pose: AutoTablePose, camera: AutoCamera,
                            profile: AutoTableProfile) -> Double {
        let L = pose.spec.length, W = pose.spec.width, m = profile.cornerMouthInset
        var s = 0.0, n = 0
        for k in kps {
            let model: [Vec2], h = profile.noseHeight
            switch k.kind {
            case .noseCorner: model = [Vec2(0, 0), Vec2(0, W), Vec2(L, W), Vec2(L, 0)]
            case .sideMouth: model = [Vec2(L / 2, 0), Vec2(L / 2, W)]
            case .cornerMouth: model = [Vec2(m, m), Vec2(m, W - m), Vec2(L - m, W - m), Vec2(L - m, m)]
            }
            let d = model.compactMap { camera.project(pose.world($0, height: h)) }.map { simd_distance($0, k.pixel) }.min()
            if let d { s += d * d; n += 1 }
        }
        return n > 0 ? (s / Double(n)).squareRoot() : .infinity
    }

    // MARK: - Partial view (lock-plan step 4)

    /// Fits a table seen only in part: ≥ 2 perpendicular visible rails (felt/wood edges), completed with
    /// the 2:1 shape and a preset. Each long/short × preset hypothesis is scored by how well its projected
    /// outer felt matches the cloth mask; an ambiguous best (another hypothesis nearly as good, e.g. every
    /// far rail out of frame) is rejected. Fusion then locks a partial fit only with ≥ 60 % of the length
    /// seen or ≥ 2 view angles (`AutoTableFusion.partialViewsAgree`).
    private func partialDetect(_ f: AutoTableFrame, seed: PartialSeed, camera: AutoCamera, plane planeIn: AutoTablePlane,
                               hintLevel: Double, profile prof: AutoTableProfile, state s: inout Work,
                               diag: inout AutoFrameDiagnostics) -> Detection? {
        // A neutral (grey/tan) cloth mask is too soft at its edges to choose a size from mask overlap.
        guard !seed.model.neutral else { diag.rejection = "partial: neutral cloth"; return nil }
        var plane = planeIn
        let img = f.image, st = Double(seed.stride)
        let W = Double(img.width), H = Double(img.height)
        let margin = 2.5 * st
        var pts = seed.boundary.filter { $0.x > margin && $0.y > margin && $0.x < W - 1 - margin && $0.y < H - 1 - margin }
        if pts.count > 1200 { let k = pts.count / 1200 + 1; pts = pts.indices.filter { $0 % k == 0 }.map { pts[$0] } }
        // 1. Straight runs of the mask outline (sequential RANSAC); occluders and the frame cut are short or curved.
        struct Run { var a: AutoP2; var b: AutoP2; var outward: AutoP2 }
        var runs: [Run] = []
        let minLen = 0.1 * (W * W + H * H).squareRoot()
        // A short rail may hold only ~5 % of the outline points: enough RANSAC draws to find it.
        for _ in 0..<6 {
            guard pts.count >= 30, let r = AutoRansac.line(pts, tolerance: 1.2 * st, iterations: 400, rng: &s.rng) else { break }
            let inl = r.inliers.map { pts[$0] }
            let dir = r.line.direction
            let ts = inl.map { simd_dot($0, dir) }
            let t0 = ts.min() ?? 0, t1 = ts.max() ?? 0
            let keep = Set(r.inliers)
            pts = pts.indices.filter { !keep.contains($0) }.map { pts[$0] }
            guard inl.count >= 25, t1 - t0 > minLen, Double(inl.count) * st > 0.5 * (t1 - t0) else { continue }
            let foot = r.line.n * -r.line.c
            let a = foot + dir * t0, b = foot + dir * t1
            // Outward = away from the cloth: probe the mask on both sides of the run's middle.
            let mid = (a + b) / 2
            func onMask(_ p: AutoP2) -> Bool {
                guard p.x.isFinite, p.y.isFinite, abs(p.x) < 1e6, abs(p.y) < 1e6 else { return false }
                let x = Int((p.x / st).rounded()), y = Int((p.y / st).rounded())
                guard x >= 0, y >= 0, x < seed.mask.width, y < seed.mask.height else { return false }
                return seed.mask.bits[y * seed.mask.width + x] != 0
            }
            let n = r.line.n
            let plus = onMask(mid + n * 3 * st), minus = onMask(mid - n * 3 * st)
            guard plus != minus else { continue }
            runs.append(Run(a: a, b: b, outward: plus ? -n : n))
        }
        guard runs.count >= 2 else { diag.rejection = "partial: < 2 rails"; return nil }
        // 2. Sub-pixel edges on each visible rail, lifted to the felt boundary height.
        var rails: [(edge: AutoRailEdge, lifted: [AutoP2], outward: AutoP2, dir: AutoP2)] = []
        for r in runs {
            guard let e = AutoRailDetector.refineSegment(img, model: seed.model, from: r.a, to: r.b, outward: r.outward,
                                                         radius: max(6, 2.5 * st), rng: &s.rng) else { continue }
            let lifted = e.points.compactMap { plane.lift($0, camera: camera, height: prof.railTopHeight) }
            guard lifted.count >= 12, let l3 = AutoLine.fit(lifted) else { continue }
            // Outward in the plane: the lifted image-outward probe.
            let m = e.points[e.points.count / 2]
            guard let p0 = plane.lift(m, camera: camera, height: prof.railTopHeight),
                  let p1 = plane.lift(m + r.outward * 4, camera: camera, height: prof.railTopHeight) else { continue }
            var nrm = l3.n
            if simd_dot(nrm, p1 - p0) < 0 { nrm = -nrm }
            rails.append((e, lifted, nrm, l3.direction))
        }
        // 3. A perpendicular pair gives a felt corner.
        var pair: (Int, Int)?
        for i in rails.indices { for j in rails.indices where j > i {
            if abs(simd_dot(rails[i].dir, rails[j].dir)) < sin(8 * .pi / 180) { pair = pair ?? (i, j) }
        } }
        guard let (i, j) = pair else { diag.rejection = "partial: no rail corner (\(runs.count) runs, \(rails.count) rails)"; return nil }
        let li = AutoLine.fit(rails[i].lifted)!, lj = AutoLine.fit(rails[j].lifted)!
        guard let C = li.intersect(lj) else { diag.rejection = "partial: parallel"; return nil }
        let di = -rails[i].outward, dj = -rails[j].outward  // inward normals (bed side)
        let c = prof.cushionWidth
        let nose = C + (di + dj) * c
        // A visible opposite rail measures the nose extent across the pair directly (e.g. both long rails).
        func spacing(parallelTo r: Int) -> Double? {
            let lr = r == i ? li : lj
            for k in rails.indices where k != i && k != j && abs(simd_dot(rails[k].dir, rails[r].dir)) > cos(8 * .pi / 180) {
                let pk = rails[k].lifted
                let d = abs(pk.map { lr.distance($0) }.reduce(0, +) / Double(pk.count))
                if d > 0.5 { return d - 2 * c }
            }
            return nil
        }
        let extentAlongDi = spacing(parallelTo: i), extentAlongDj = spacing(parallelTo: j)
        // 4. Hypotheses: which visible rail is long, and the preset.
        struct Hyp { var rect: AutoRect; var size: TableSize; var iou: Double; var iLong: Bool }
        var hyps: [Hyp] = []
        for size in TableSize.allCases {
            let spec = TableSpec(size: size)
            for iLong in [true, false] {
                // Rail i runs along dj from the corner; rail j along di.
                let li = iLong ? spec.length : spec.width, lj = iLong ? spec.width : spec.length
                if let e = extentAlongDi, abs(e - lj) / lj > 0.06 { continue }
                if let e = extentAlongDj, abs(e - li) / li > 0.06 { continue }
                let center = nose + dj * (li / 2) + di * (lj / 2)
                let u = iLong ? dj : di
                let rect = AutoRect(center: center, theta: atan2(u.y, u.x), a: spec.length / 2, b: spec.width / 2)
                hyps.append(Hyp(rect: rect, size: size, iou: maskIoU(rect, seed: seed, camera: camera, plane: plane, profile: prof),
                                iLong: iLong))
            }
        }
        hyps.sort { $0.iou > $1.iou }
        guard let best = hyps.first, best.iou >= 0.75 else { diag.rejection = "partial: mask disagrees"; return nil }
        if hyps.count > 1, hyps[1].iou > best.iou - 0.05 { diag.rejection = "partial: ambiguous size"; return nil }
        // 5. Refine centre + heading at the fixed preset size from every visible rail's edge samples.
        var rect = best.rect
        var samples: [AutoRectFitter.EdgeSample] = []
        for r in rails {
            let ang = autoWrapPi(atan2(r.outward.y, r.outward.x) - rect.theta)
            guard ang.isFinite else { diag.rejection = "partial: fit"; return nil }
            let side = ((Int((ang / (.pi / 2)).rounded()) % 4) + 4) % 4
            for p in r.lifted { samples.append(.init(p: p, side: side, offset: c)) }
        }
        guard let fit = AutoRectFitter.fit(rect, edges: samples, mode: .fixed(a: rect.a, b: rect.b)) else {
            diag.rejection = "partial: fit"; return nil
        }
        rect = fit.rect
        // LiDAR cloth level from the visible part of the bed.
        let bedQuad = [rect.point(1, 1), rect.point(-1, 1), rect.point(-1, -1), rect.point(1, -1)]
            .compactMap { camera.project(plane.to3D($0)) }
        if bedQuad.count == 4 {
            refineLevel(f, camera: camera, quad: bedQuad, plane: &plane, hintLevel: hintLevel, state: &s, diag: &diag)
        }
        let spec = TableSpec(size: best.size)
        let axis = plane.e1 * rect.u.x + plane.e2 * rect.u.y
        guard let pose = AutoTableFusion.pose(center: plane.to3D(rect.center), axis: axis, up: plane.normal, spec: spec,
                                              snapped: best.size, measured: (spec.length, spec.width), headToFoot: axis) else { return nil }
        let allPts = rails.flatMap(\.edge.points)
        diag.railLines = rails.map(\.edge.line.abc)
        diag.reprojectionRMS = Self.reprojectionRMS(allPts, pose: pose, plane: plane, camera: camera, profile: prof)
        guard diag.reprojectionRMS < config.maxFrameRMS else { diag.rejection = "partial: reprojection"; return nil }
        guard viewElevation(camera, center: pose.center, up: plane.normal) >= config.minViewElevation else {
            diag.rejection = "view too shallow"; return nil
        }
        // Visible fraction of the length: the long rails' lifted extent along the axis.
        var visible = 0.0
        for r in rails where abs(simd_dot(r.dir, rect.u)) > 0.9 {
            let t = r.lifted.map { simd_dot($0 - rect.center, rect.u) }
            // Samples lie on the outer felt edge (−c…L+c): count only what can be playing length.
            visible = max(visible, ((t.max() ?? 0) - (t.min() ?? 0) - 2 * c) / spec.length)
        }
        diag.visibleLengthFraction = min(1, visible)
        diag.railTopHeight = prof.railTopHeight
        var m = AutoTableMeasurement(center: pose.center, axis: pose.xAxis, up: plane.normal,
                                     measuredLength: spec.length, measuredWidth: spec.width, snapped: best.size,
                                     cameraPosition: camera.position)
        m.visibleLengthFraction = min(0.99, visible)
        return Detection(measurement: m, edgePoints: allPts, plane: plane, profile: prof)
    }

    /// IoU (on the mask grid, inside the image) of a hypothesised outer felt rectangle and the cloth mask.
    private func maskIoU(_ rect: AutoRect, seed: PartialSeed, camera: AutoCamera, plane: AutoTablePlane,
                         profile prof: AutoTableProfile) -> Double {
        let c = prof.cushionWidth
        var r = rect; r.a += c; r.b += c
        let poly = [r.point(1, 1), r.point(-1, 1), r.point(-1, -1), r.point(1, -1)]
            .compactMap { camera.project(plane.to3D($0, height: prof.railTopHeight)) }
        guard poly.count == 4 else { return 0 }
        let st = Double(seed.stride), w = seed.mask.width, h = seed.mask.height
        var both = 0, either = 0
        for y in Swift.stride(from: 0, to: h, by: 2) {
            for x in Swift.stride(from: 0, to: w, by: 2) {
                let inMask = seed.mask.bits[y * w + x] != 0
                let inPoly = AutoPolygon.contains(poly, AutoP2(Double(x) * st, Double(y) * st))
                if inMask && inPoly { both += 1 }
                if inMask || inPoly { either += 1 }
            }
        }
        return either > 0 ? Double(both) / Double(either) : 0
    }

    private func viewElevation(_ camera: AutoCamera, center: SIMD3<Double>, up: SIMD3<Double>) -> Double {
        let d = camera.position - center
        let l = simd_length(d)
        return l > 1e-6 ? asin(min(1, abs(simd_dot(d, up)) / l)) : .pi / 2
    }

    /// Table-shaped: outer felt aspect 1.6–2.5 (any size; the preset only snaps within 6 %).
    static func plausibleAspect(_ ratio: Double) -> Bool { ratio >= 1.6 && ratio <= 2.5 }

    // MARK: - Validation, pockets, confidence

    /// RMS pixel distance of edge samples to the nearest re-projected outer felt line of `pose`.
    static func reprojectionRMS(_ pts: [AutoP2], pose: AutoTablePose, plane: AutoTablePlane, camera: AutoCamera,
                                profile: AutoTableProfile) -> Double {
        let c = profile.cushionWidth, L = pose.spec.length, W = pose.spec.width, h = profile.railTopHeight
        let o = [Vec2(-c, -c), Vec2(-c, W + c), Vec2(L + c, W + c), Vec2(L + c, -c)]
        let q = o.compactMap { camera.project(pose.world($0, height: h)) }
        guard q.count == 4 else { return .infinity }
        let lines = (0..<4).compactMap { AutoLine(through: q[$0], q[($0 + 1) % 4]) }
        guard lines.count == 4, !pts.isEmpty else { return .infinity }
        var s = 0.0
        for p in pts {
            let d = lines.map { abs($0.distance(p)) }.min()!
            s += d * d
        }
        return (s / Double(pts.count)).squareRoot()
    }

    private func pocketScores(_ img: AutoRGBImage, camera: AutoCamera, pose: AutoTablePose,
                              profile: AutoTableProfile) -> [Pocket: Double] {
        let L = pose.spec.length, W = pose.spec.width, h = profile.noseHeight
        let e1 = pose.xAxis, e2 = simd_cross(pose.up, pose.xAxis)
        let d = 0.022
        let pos: [Pocket: Vec2] = [.headLeft: Vec2(-d, -d), .headRight: Vec2(-d, W + d), .footLeft: Vec2(L + d, -d),
                                   .footRight: Vec2(L + d, W + d), .sideLeft: Vec2(L / 2, -0.03), .sideRight: Vec2(L / 2, W + 0.03)]
        var out: [Pocket: Double] = [:]
        for (p, v) in pos {
            if let s = AutoPocketEvidence.score(img, camera: camera, center: pose.world(v, height: h), e1: e1, e2: e2,
                                                radius: 0.02, darkBelow: 45) { out[p] = s }
        }
        return out
    }

    private func confidence(state: AutoLockState, progress: Double, rms: Double, pockets: [Pocket: Double]) -> Double {
        let base: Double
        switch state {
        case .searching: return 0
        case .converging: base = 0.7 * progress
        case .locked: base = 1
        }
        let r = rms.isFinite ? exp(-rms / 1.5) : 0.3
        let p = pockets.isEmpty ? 0.5 : pockets.values.reduce(0, +) / Double(pockets.count)
        return max(0, min(1, base * (0.5 + 0.5 * r) * (0.6 + 0.4 * p)))
    }
}
