import Testing
import Foundation
@testable import Geometry

// Adversarial QA audit of Geometry (phase/1-core). Findings G1-G6 and A2 are fixed; these are regressions.

private let inch = 0.0254

@Suite("Audit: WPA dimensions")
struct AuditWPADimensionTests {
    // WPA Equipment Specs: 9 ft 100" x 50", 8 ft 92" x 46", tolerance +/- 1/8".
    @Test(arguments: [(TableSize.nineFoot, 100.0), (.eightFoot, 92.0)])
    func wpaLengthWithinEighthInch(size: TableSize, inches: Double) {
        let s = TableSpec(size: size)
        #expect(abs(s.length / inch - inches) <= 0.125)
        #expect(abs(s.width / inch - inches / 2) <= 0.125)
    }

    @Test(arguments: TableSize.allCases)
    func exactTwoToOne(size: TableSize) {
        let s = TableSpec(size: size)
        #expect(s.length == 2 * s.width)
        #expect(s.length > 0 && s.width > 0)
    }

    @Test func presetsStrictlyOrdered() {
        let l = TableSize.allCases.map(\.playingLength)
        #expect(TableSpec(size: .sevenFoot).length < TableSpec(size: .eightFoot).length)
        #expect(TableSpec(size: .eightFoot).length < TableSpec(size: .nineFoot).length)
        #expect(Set(l).count == 3)
    }

    // WPA: ball 2 1/4" +/- .005".
    @Test func ballDiameterWithinWPATolerance() {
        #expect(abs(2 * TableSpec.ballRadius / inch - 2.25) <= 0.005)
    }

    // WPA: corner mouth 4.5"-4.625", side mouth 5"-5.125".
    @Test(arguments: TableSize.allCases)
    func pocketMouthsWithinWPA(size: TableSize) {
        let s = TableSpec(size: size)
        #expect((4.5...4.625).contains(s.cornerMouth / inch + 1e-12) || abs(s.cornerMouth / inch - 4.5) < 1e-9)
        #expect((5.0...5.125).contains(s.sideMouth / inch + 1e-12) || abs(s.sideMouth / inch - 5.0) < 1e-9)
        #expect(s.sideMouth > s.cornerMouth)
        // A ball must physically fit through every mouth.
        #expect(s.cornerMouth > 2 * TableSpec.ballRadius)
    }

    // A rack of 15 (5 rows, apex on foot spot, toward head) must fit between foot spot and foot rail.
    @Test(arguments: TableSize.allCases)
    func rackFitsBehindFootSpot(size: TableSize) {
        let s = TableSpec(size: size)
        let d = 2 * TableSpec.ballRadius
        let rackDepth = 4 * d * (3.0).squareRoot() / 2 + TableSpec.ballRadius
        #expect(s.footSpot.x + rackDepth < s.length)
        #expect(5 * d < s.width)
    }
}

@Suite("Audit: pockets, spots, head string")
struct AuditLayoutTests {
    @Test(arguments: TableSize.allCases)
    func headEndAtXZeroFootAtLength(size: TableSize) {
        let s = TableSpec(size: size)
        #expect(s.pocketCenter(.headLeft) == Vec2(0, 0))
        #expect(s.pocketCenter(.headRight) == Vec2(0, s.width))
        #expect(s.pocketCenter(.footLeft) == Vec2(s.length, 0))
        #expect(s.pocketCenter(.footRight) == Vec2(s.length, s.width))
        #expect(s.pocketCenter(.sideLeft) == Vec2(s.length / 2, 0))
        #expect(s.pocketCenter(.sideRight) == Vec2(s.length / 2, s.width))
    }

    @Test(arguments: TableSize.allCases)
    func headSpotOnHeadStringAndInsideKitchenBoundary(size: TableSize) {
        let s = TableSpec(size: size)
        #expect(s.headSpot.x == s.headStringX)
        #expect(s.headStringX > 0 && s.headStringX < s.length / 2)
        #expect(s.footSpot.x > s.length / 2)
        // Spots are mirror images about the side-pocket line.
        #expect(abs((s.footSpot.x - s.length / 2) - (s.length / 2 - s.headSpot.x)) < 1e-12)
        #expect(s.headSpot.y == s.width / 2 && s.footSpot.y == s.width / 2)
    }

    @Test(arguments: TableSize.allCases)
    func headSpotClosestToHeadPockets(size: TableSize) {
        let s = TableSpec(size: size)
        let dHead = s.headSpot.distance(to: s.pocketCenter(.headLeft))
        let dFoot = s.headSpot.distance(to: s.pocketCenter(.footLeft))
        #expect(dHead < dFoot)
        #expect(s.footSpot.distance(to: s.pocketCenter(.footRight)) < s.footSpot.distance(to: s.pocketCenter(.headRight)))
    }

    @Test func pocketsUniqueAndSixWithTwoSides() {
        let s = TableSpec(size: .nineFoot)
        #expect(Set(s.pockets).count == 6)
        #expect(s.pockets.filter(\.isSide).count == 2)
        #expect(Set(s.pockets.map { s.pocketCenter($0) }).count == 6)
    }

    // Spots/head string must follow a LiDAR-overridden length rather than the preset.
    @Test func derivedGeometryFollowsOverriddenDimensions() {
        var s = TableSpec(size: .sevenFoot)
        s.length = 1.98; s.width = 0.99
        #expect(s.headStringX == 1.98 * 0.25)
        #expect(s.footSpot == Vec2(1.98 * 0.75, 0.495))
        #expect(s.pocketCenter(.footRight) == Vec2(1.98, 0.99))
    }

    // G1: the documented frame must match the code (head-left corner at the origin, +x toward the foot).
    @Test func documentedFrameMatchesCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Tests/GeometryTests
            .deletingLastPathComponent().deletingLastPathComponent()              // Packages/CueCore
        let repo = root.deletingLastPathComponent().deletingLastPathComponent()
        let interfaces = try String(contentsOf: repo.appending(path: "docs/INTERFACES.md"), encoding: .utf8)
        #expect(interfaces.contains("origin = head-left cushion nose, +x toward the foot"))
        for f in ["Table.swift", "Vec2.swift"] {
            let src = try String(contentsOf: root.appending(path: "Sources/Geometry/\(f)"), encoding: .utf8)
            #expect(!src.contains("foot-left"), "\(f) still documents a foot-left origin")
            #expect(!src.contains("toward the head"), "\(f) still documents +x toward the head")
        }
        let s = TableSpec(size: .nineFoot)
        #expect(s.pocketCenter(.headLeft) == .zero && s.footSpot.x > s.headSpot.x)
    }

    // G4: a decoded (peer / persisted) spec must have positive, finite, roughly 2:1 dimensions and
    // pocket mouths a ball fits through.
    @Test(arguments: [
        #"{"size":"nineFoot","length":-1,"width":0,"cornerMouth":0.1143,"sideMouth":0.127}"#,
        #"{"size":"nineFoot","length":0,"width":0,"cornerMouth":0.1143,"sideMouth":0.127}"#,
        #"{"size":"nineFoot","length":2.54,"width":-1.27,"cornerMouth":0.1143,"sideMouth":0.127}"#,
        #"{"size":"nineFoot","length":1e400,"width":1.27,"cornerMouth":0.1143,"sideMouth":0.127}"#,
        #"{"size":"nineFoot","length":2.54,"width":2.54,"cornerMouth":0.1143,"sideMouth":0.127}"#,
        #"{"size":"nineFoot","length":2.54,"width":0.5,"cornerMouth":0.1143,"sideMouth":0.127}"#,
        #"{"size":"nineFoot","length":2.54,"width":1.27,"cornerMouth":0.01,"sideMouth":0.127}"#,
        #"{"size":"nineFoot","length":2.54,"width":1.27,"cornerMouth":0.1143,"sideMouth":-0.127}"#,
    ])
    func rejectsDegenerateDimensions(json: String) throws {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TableSpec.self, from: Data(json.utf8)) }
    }

    @Test func nonFiniteDimensionsAreInvalid() {
        var s = TableSpec(size: .nineFoot)
        #expect(s.isValid)
        s.length = .nan
        #expect(!s.isValid)
        s = TableSpec(size: .nineFoot); s.width = .infinity
        #expect(!s.isValid)
    }

    @Test(arguments: TableSize.allCases)
    func validSpecsRoundTrip(size: TableSize) throws {
        var s = TableSpec(size: size)
        s.length *= 0.99                                   // LiDAR-measured, slightly off 2:1
        let back = try JSONDecoder().decode(TableSpec.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite("Audit: BallID")
struct AuditBallIDTests {
    @Test func initRejectsOutOfRange() {
        #expect(BallID(-1) == nil)
        #expect(BallID(16) == nil)
        #expect(BallID(Int.min) == nil)
        #expect(BallID(0) == .cue)
        #expect(BallID(8) == .eight)
        #expect(BallID(9) == .nine)
    }

    @Test func groupsPartitionObjectBalls() {
        let solids = BallID.allObjectBalls.filter { $0.group == .solids }
        let stripes = BallID.allObjectBalls.filter { $0.group == .stripes }
        #expect(solids.map(\.number) == Array(1...7))
        #expect(stripes.map(\.number) == Array(9...15))
        #expect(BallGroup.solids.other == .stripes && BallGroup.stripes.other == .solids)
        #expect(!BallID.allObjectBalls.contains(.cue))
        #expect(BallID.allObjectBalls == BallID.allObjectBalls.sorted())
    }

    // G2: decoding enforces the failable init's 0...15 guard.
    @Test
    func decodeRejectsOutOfRange() throws {
        #expect(try JSONDecoder().decode(BallID.self, from: Data(#"{"number":15}"#.utf8)) == BallID(15))
        for n in [16, 99, -3] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(BallID.self, from: Data(#"{"number":\#(n)}"#.utf8))
            }
        }
    }
}

@Suite("Audit: Codable stability")
struct AuditCodableTests {
    // Wire/storage format pins: renaming a case breaks persisted data and mesh peers on older builds.
    @Test func enumRawValuesArePinned() throws {
        #expect(TableSize.allCases.map(\.rawValue) == ["sevenFoot", "eightFoot", "nineFoot"])
        #expect(Pocket.allCases.map(\.rawValue) == ["footLeft", "footRight", "sideLeft", "sideRight", "headLeft", "headRight"])
        #expect(MotionState.stationary.rawValue == "stationary" && MotionState.pocketed.rawValue == "pocketed")
        #expect(BallGroup.allCases.map(\.rawValue) == ["solids", "stripes"])
    }

    @Test func tableSpecJSONKeysPinned() throws {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let obj = try JSONSerialization.jsonObject(with: enc.encode(TableSpec(size: .eightFoot))) as! [String: Any]
        #expect(Set(obj.keys) == ["size", "length", "width", "cornerMouth", "sideMouth"])
        #expect(obj["size"] as? String == "eightFoot")
    }

    @Test func ballIDEncodesAsNumberObject() throws {
        let s = String(decoding: try JSONEncoder().encode(BallID(7)!), as: UTF8.self)
        #expect(s == #"{"number":7}"#)
    }

    @Test(arguments: TableSize.allCases)
    func fullStateRoundTripAllSizes(size: TableSize) throws {
        var st = TableState(spec: TableSpec(size: size))
        st.balls[.cue] = BallState(position: Vec2(0.1, 0.2), velocity: Vec2(-1, 2),
                                   angularVelocity: SIMD3Codable(1, -2, 3), motion: .sliding)
        for b in BallID.allObjectBalls { st.balls[b] = BallState(position: Vec2(Double(b.number) / 10, 0.3), motion: .pocketed) }
        let back = try JSONDecoder().decode(TableState.self, from: JSONEncoder().encode(st))
        #expect(back == st)
        #expect(back.onTable.count == 1)
        let p = try PropertyListDecoder().decode(TableState.self, from: PropertyListEncoder().encode(st))
        #expect(p == st)
    }

    // Non-String/Int dictionary keys encode as a flat [k, v, k, v] array whose order follows
    // hash-seeded iteration, so equal states produce different bytes across processes.
    @Test func ballsDictionaryEncodesAsFlatArray() throws {
        var st = TableState(spec: TableSpec(size: .nineFoot))
        st.balls[.cue] = BallState(position: .zero)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(st)) as! [String: Any]
        #expect(obj["balls"] is [Any])
    }

    // G3: no backward-compatibility contract exists for payloads without mouth widths, so they are
    // rejected rather than silently defaulted.
    @Test func decodeWithoutMouthsIsRejected() throws {
        let json = #"{"size":"nineFoot","length":2.54,"width":1.27}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TableSpec.self, from: Data(json.utf8)) }
    }

    // G5: duplicate keys in a peer-sent balls array are rejected.
    @Test
    func duplicateBallKeysRejected() throws {
        let ball = #"{"position":{"x":0,"y":0},"velocity":{"x":0,"y":0},"angularVelocity":{"x":0,"y":0,"z":0},"motion":"stationary"}"#
        let spec = #"{"size":"nineFoot","length":2.54,"width":1.27,"cornerMouth":0.1143,"sideMouth":0.127}"#
        let json = #"{"spec":\#(spec),"balls":[{"number":1},\#(ball),{"number":1},\#(ball)]}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TableState.self, from: Data(json.utf8)) }
    }

    @Test func nonFiniteVec2RefusesToEncode() {
        #expect(throws: (any Error).self) { try JSONEncoder().encode(Vec2(.nan, 0)) }
        #expect(throws: (any Error).self) { try JSONEncoder().encode(Vec2(.infinity, 0)) }
    }
}

@Suite("Audit: Vec2")
struct AuditVec2Tests {
    @Test func rotationAndAngle() {
        let r = Vec2(1, 0).rotated(by: .pi / 2)
        #expect(abs(r.x) < 1e-12 && abs(r.y - 1) < 1e-12)
        #expect(abs(Vec2(0, 1).angle - .pi / 2) < 1e-12)
        #expect(abs(Vec2(-1, 0).angle - .pi) < 1e-12)
        #expect(Vec2(3, 4).perpendicular.dot(Vec2(3, 4)) == 0)
    }

    @Test func tinyAndHugeNormalize() {
        // A2: a nonzero vector must never normalize to zero.
        #expect(abs(Vec2(1e-200, 1e-200).normalized.length - 1) < 1e-9)
        #expect(abs(Vec2(5e-324, 0).normalized.length - 1) < 1e-9)
        #expect(Vec2(1e-170, 0).length == 1e-170)
        #expect(Vec2(-0.0, 0).normalized == .zero)
    }

    // G6: length must not overflow for large finite components.
    @Test
    func lengthDoesNotOverflow() {
        #expect(Vec2(1e200, 0).length == 1e200)
        #expect(abs(Vec2(1e200, 1e200).normalized.length - 1) < 1e-9)
    }
}
