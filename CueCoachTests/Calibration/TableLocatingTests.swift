import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

struct TableLocatingTests {
    let scene = SyntheticTableScene.demo()

    func frame(_ t: Double, camera: CameraModel? = nil) throws -> LocatorFrame {
        var s = scene
        if let camera { s.camera = camera }
        let cg = try #require(s.render())
        let img = try #require(PixelImage(cgImage: cg))
        let plane = LocatorPlane(center: scene.frame.world(Vec2(scene.frame.spec.length / 2, scene.frame.spec.width / 2)),
                                 extent: SIMD2(1.0, 0.6), isTable: true)
        let floor = LocatorPlane(center: SIMD3(0, 0, 0), extent: SIMD2(5, 5), isTable: false)
        return LocatorFrame(image: img, camera: s.camera, planes: [floor, plane], timestamp: t)
    }

    @Test func convergesAndLocksWithoutTaps() async throws {
        let loc = FeltQuadLocator()
        var last: TableEstimate?
        var confidences: [Double] = []
        for i in 0..<8 {
            last = await loc.ingest(try frame(Double(i) * 0.25))
            confidences.append(last?.confidence ?? 0)
        }
        let est = try #require(last)
        #expect(est.locked)
        #expect(est.size == .sevenFoot)
        #expect(confidences.first! < confidences.last!)
        let truth = scene.frame.corners.map { scene.frame.world($0) }
        for c in est.corners { #expect(truth.map { simd_distance($0, c) }.min()! < 0.05) }
    }

    @Test func picksTheTablePlaneNotTheFloor() throws {
        let f = try frame(0)
        let centre = Vec2(960, 600)
        let p = try #require(LocatorMath.plane(for: centre, camera: f.camera, planes: f.planes))
        #expect(abs(p.point.y - 0.76) < 1e-9)
    }

    @Test func alignKeepsCornerIdentity() {
        let ref = [SIMD3<Double>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 2), SIMD3(0, 0, 2)]
        let new = [ref[2] + SIMD3(0.01, 0, 0), ref[0], ref[3], ref[1]]
        let a = LocatorMath.align(new, to: ref)
        for i in 0..<4 { #expect(simd_distance(a[i], ref[i]) < 0.02) }
    }

    @Test func resetForgetsTheLock() async throws {
        let loc = FeltQuadLocator()
        for i in 0..<8 { _ = await loc.ingest(try frame(Double(i) * 0.25)) }
        await loc.reset()
        let e = await loc.ingest(try frame(10))
        #expect(e?.locked == false)
    }
}
