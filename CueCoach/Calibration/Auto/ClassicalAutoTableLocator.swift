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
        /// Plausible LiDAR rail-cap heights above the cloth (m); outside → keep the profile's value.
        var railTopHeightRange: ClosedRange<Double> = 0.025...0.07
    }

    /// Per-frame detector state. Copied out of the lock, worked on without it, written back.
    private struct Work {
        var fused: AutoTablePose?
        var model: AutoClothModel?
        /// Recent LiDAR cloth levels (world height along the plane normal).
        var clothLevels: [Double] = []
        /// Recent LiDAR rail-cap heights above the cloth.
        var railHeights: [Double] = []
        var rng = AutoRandom()
    }

    private struct State {
        var fusion: AutoTableFusion
        var work = Work()
        var latest: AutoTableEstimate?
        var lastTimestamp: Double?
    }

    let config: Config
    private let keypointProvider: (any TableKeypointProvider)?
    private let state: Mutex<State>

    init(config: Config = Config(), keypoints: (any TableKeypointProvider)? = nil) {
        self.config = config
        keypointProvider = keypoints
        state = Mutex(State(fusion: AutoTableFusion(config: config.fusion)))
    }

    var latest: AutoTableEstimate? { state.withLock { $0.latest } }

    func flipHeadFoot() {
        state.withLock { s in
            s.fusion.flip()
            if var l = s.latest { l.pose = s.fusion.fused; s.latest = l }
        }
    }

    func reset() {
        state.withLock { s in s = State(fusion: AutoTableFusion(config: config.fusion)) }
    }

    func process(_ frame: AutoTableFrame) -> AutoTableEstimate {
        let t0 = Date()
        // 1. Under the lock: skip unusable frames, snapshot the detector state.
        enum Gate { case skip(AutoTableEstimate), run(Work) }
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
            var w = s.work
            w.fused = s.fusion.fused
            return .run(w)
        }
        var work: Work
        switch gate {
        case .skip(let e): return e
        case .run(let w): work = w
        }

        // 2. Detection (and the keypoint model) without the lock: readers and flips never wait for it.
        var diag = AutoFrameDiagnostics()
        let camera = AutoCamera(intrinsics: frame.intrinsics, cameraToWorld: frame.cameraToWorld)
        let det = detect(frame, camera: camera, state: &work, diag: &diag)

        // 3. Under the lock: write back, fuse, validate against the fused pose.
        return state.withLock { s in
            s.work = work
            s.work.fused = nil
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
        if edges == nil {
            edges = fullSearch(f, camera: camera, plane: plane, profile: prof, state: &s, diag: &diag)
            if edges != nil { diag.path = .full }
        }
        let keypoints = keypointProvider?.keypoints(in: img, intrinsics: f.intrinsics) ?? []

        if edges == nil {
            // Keypoint-only fallback (LiDAR level from the keypoint quad).
            let kq = keypoints.filter { $0.kind == .cornerPocket && $0.confidence >= 0.3 }.map(\.pixel)
            if kq.count == 4 {
                let cen = kq.reduce(AutoP2.zero, +) / 4
                let ordered = kq.sorted { atan2($0.y - cen.y, $0.x - cen.x) < atan2($1.y - cen.y, $1.x - cen.x) }
                refineLevel(f, camera: camera, quad: ordered, plane: &plane, hintLevel: hintLevel, state: &s, diag: &diag)
            }
            guard let det = keypointOnly(keypoints, camera: camera, plane: plane, profile: prof, diag: &diag) else {
                if diag.rejection == nil { diag.rejection = "no rails" }
                return nil
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
        if let d = f.depth {
            let Q = imgCorners.compactMap { plane.lift($0, camera: camera, height: prof.railTopHeight) }
            if Q.count == 4, let r = AutoPlaneRefiner.railTopHeight(depth: d, camera: camera, imageWidth: img.width,
                                                                     imageHeight: img.height, plane: plane, feltCorners: Q),
               config.railTopHeightRange.contains(r.height) {
                s.railHeights.append(r.height)
                if s.railHeights.count > 15 { s.railHeights.removeFirst() }
                prof = effectiveProfile(s)
            }
        }

        // 4. Lift to the plane and fit the rectangle.
        guard let fit = fitRectangle(rails: rails, corners: imgCorners, keypoints: keypoints, camera: camera,
                                     plane: plane, profile: prof, diag: &diag) else { return nil }
        let allPts = rails.flatMap(\.points)
        let pose0 = AutoTableFusion.pose(center: plane.to3D(fit.rect.center), axis: plane.e1 * fit.rect.u.x + plane.e2 * fit.rect.u.y,
                                         up: plane.normal, spec: fit.spec, snapped: fit.snapped,
                                         measured: (fit.measuredL, fit.measuredW), headToFoot: plane.e1 * fit.rect.u.x + plane.e2 * fit.rect.u.y)!
        diag.reprojectionRMS = Self.reprojectionRMS(allPts, pose: pose0, plane: plane, camera: camera, profile: prof)
        guard diag.reprojectionRMS < config.maxFrameRMS else { diag.rejection = "reprojection"; return nil }
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
        if let h = f.plane { return AutoTablePlane(origin: h.point, normal: h.normal) }
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

    private func fullSearch(_ f: AutoTableFrame, camera: AutoCamera, plane: AutoTablePlane, profile: AutoTableProfile,
                            state s: inout Work, diag: inout AutoFrameDiagnostics) -> [AutoRailEdge]? {
        let img = f.image
        let stride = max(2, img.width / config.coarseWidth)
        var gate: [UInt8]?
        var learnGate: [UInt8]?
        if let d = f.depth {
            gate = AutoPlaneRefiner.gate(depth: d, camera: camera, imageWidth: img.width, imageHeight: img.height,
                                         plane: plane, tolerance: 0.12, grow: 3)
            learnGate = AutoPlaneRefiner.gate(depth: d, camera: camera, imageWidth: img.width, imageHeight: img.height,
                                              plane: plane, tolerance: 0.04)
        }
        let dw = f.depth?.width ?? 0, dh = f.depth?.height ?? 0
        let accept: ((Int, Int) -> Bool)? = learnGate.map { g in
            { x, y in g[(y * dh / img.height) * dw + x * dw / img.width] != 0 }
        }
        guard let model = AutoClothModel.learn(img, stride: stride, accept: accept)
                ?? AutoClothModel.learn(img, stride: stride) ?? s.model else {
            diag.rejection = "no cloth colour"; return nil
        }
        let raw = AutoClothSegmenter.mask(img, model: model, stride: stride, gate: gate, gateWidth: dw, gateHeight: dh)
        let (comp, size) = AutoClothSegmenter.largestComponent(AutoClothSegmenter.open(raw))
        guard size > comp.width * comp.height / 30 else { diag.rejection = "cloth too small"; return nil }
        let (pts, border) = AutoClothSegmenter.boundary(comp)
        // The whole table must be in view; a component hugging the frame is not a table (or is cut off).
        guard border < (comp.width + comp.height) / 6 else { diag.rejection = "cloth touches frame"; return nil }
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
            return ratio > 1.5 && ratio < 2.5 && abs(len[0] - len[2]) / a < 0.15 && abs(len[1] - len[3]) / b < 0.15
        }
        guard let coarse = AutoRailDetector.coarseLines(boundary: pts, stride: stride, rng: &s.rng, accept: isTableQuad),
              let q = AutoRailDetector.corners(coarse), AutoPolygon.area(q) > Double(img.width * img.height) / 40,
              q.allSatisfy({ abs($0.x - Double(img.width) / 2) < Double(img.width) && abs($0.y - Double(img.height) / 2) < Double(img.height) })
        else { diag.rejection = "no quad"; return nil }
        guard let edges = AutoRailDetector.refine(img, model: model, corners: q, radius: max(6, 2.5 * Double(stride)),
                                                  rng: &s.rng) else { diag.rejection = "edge refine"; return nil }
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

    private func fitRectangle(rails: [AutoRailEdge], corners q: [AutoP2], keypoints: [AutoTableKeypoint],
                              camera: AutoCamera, plane: AutoTablePlane, profile prof: AutoTableProfile,
                              diag: inout AutoFrameDiagnostics) -> RectFit? {
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
        for (i, r) in rails.enumerated() {
            for p in r.points {
                if let w = plane.lift(p, camera: camera, height: hr) {
                    samples.append(.init(p: w, side: side[i], offset: c))
                }
            }
        }
        guard let free = AutoRectFitter.fit(rect, edges: samples, mode: .free) else { diag.rejection = "fit"; return nil }
        rect = free.rect
        let kp = keypointSamples(keypoints, rect: rect, camera: camera, plane: plane, profile: prof)
        diag.keypointsUsed = kp.count
        if !kp.isEmpty, let f2 = AutoRectFitter.fit(rect, edges: samples, points: kp, mode: .free) { rect = f2.rect }
        let L = 2 * rect.a, W = 2 * rect.b
        let snap = AutoRectFitter.snap(length: L, width: W)
        var spec = TableSpec(size: snap.size)
        var snapped: TableSize?
        let final: AutoRect
        if snap.relativeError <= 0.06,
           let f = AutoRectFitter.fit(rect, edges: samples, points: kp, mode: .fixed(a: spec.length / 2, b: spec.width / 2)) {
            final = f.rect; snapped = snap.size
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
            let h = k.kind == .cushionCorner ? prof.railTopHeight : prof.noseHeight
            let grow = k.kind == .cushionCorner ? prof.cushionWidth : 0
            guard let p = plane.lift(k.pixel, camera: camera, height: h) else { continue }
            let cands: [(Double, Double)] = k.kind == .sidePocket ? [(0, 1), (0, -1)] : [(1, 1), (1, -1), (-1, 1), (-1, -1)]
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
        let corners = kps.filter { $0.kind == .cornerPocket && $0.confidence >= 0.3 }
            .compactMap { plane.lift($0.pixel, camera: camera, height: prof.noseHeight) }
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
        let kp = keypointSamples(kps, rect: rect, camera: camera, plane: plane, profile: prof)
        guard kp.count >= 4, let free = AutoRectFitter.fit(rect, edges: [], points: kp, mode: .free) else { return nil }
        diag.keypointsUsed = kp.count
        let snap = AutoRectFitter.snap(length: 2 * free.rect.a, width: 2 * free.rect.b)
        let spec = TableSpec(size: snap.size)
        guard snap.relativeError <= 0.06,
              let fixed = AutoRectFitter.fit(free.rect, edges: [], points: kp, mode: .fixed(a: spec.length / 2, b: spec.width / 2))
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
        let L = pose.spec.length, W = pose.spec.width, c = profile.cushionWidth
        var s = 0.0, n = 0
        for k in kps {
            let model: [Vec2], h: Double
            switch k.kind {
            case .cornerPocket: model = [Vec2(0, 0), Vec2(0, W), Vec2(L, W), Vec2(L, 0)]; h = profile.noseHeight
            case .sidePocket: model = [Vec2(L / 2, 0), Vec2(L / 2, W)]; h = profile.noseHeight
            case .cushionCorner: model = [Vec2(-c, -c), Vec2(-c, W + c), Vec2(L + c, W + c), Vec2(L + c, -c)]; h = profile.railTopHeight
            }
            let d = model.compactMap { camera.project(pose.world($0, height: h)) }.map { simd_distance($0, k.pixel) }.min()
            if let d { s += d * d; n += 1 }
        }
        return n > 0 ? (s / Double(n)).squareRoot() : .infinity
    }

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
