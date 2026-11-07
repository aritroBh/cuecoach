import Foundation
import Geometry
import Testing
@testable import Stats

private let footRight = spec7.pocketCenter(.footRight)
private let sideRight = spec7.pocketCenter(.sideRight)
/// Object ball 0.4 m from the foot-right corner along the diagonal-ish line.
private let obj = Vec2(spec7.length - 0.35, spec7.width - 0.25)

private func extractCut(_ degrees: Double, distance: Double = 0.3, side: Double = 1) -> ShotFeatures {
    let cue = cuePosition(object: obj, pocket: footRight, degrees: degrees, distance: distance, side: side)
    let pre = table([0: cue, 1: obj])
    return ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: potTrace(1, .footRight))
}

@Suite("ShotFeatures — cut-angle buckets (SPEC §6: 0-15/15-30/30-45/45-60/60+)")
struct CutBucketTests {
    @Test(arguments: [(0.0, CutBucket.c0to15), (5, .c0to15), (14.9, .c0to15),
                      (15.1, .c15to30), (29.9, .c15to30), (30.1, .c30to45), (44.9, .c30to45),
                      (45.1, .c45to60), (59.9, .c45to60), (60.1, .c60plus), (80, .c60plus)])
    func bucketsByAngle(_ degrees: Double, _ expected: CutBucket) {
        #expect(extractCut(degrees).cutBucket == expected)
    }

    @Test func cutDirectionDoesNotMatter() {
        #expect(extractCut(35, side: -1).cutBucket == .c30to45)
    }

    @Test func bucketFromDegrees_lowerBoundInclusive() {
        #expect(CutBucket(degrees: 15) == .c15to30)
        #expect(CutBucket(degrees: 30) == .c30to45)
        #expect(CutBucket(degrees: 45) == .c45to60)
        #expect(CutBucket(degrees: 60) == .c60plus)
        #expect(CutBucket(degrees: 179) == .c60plus)
        #expect(CutBucket(degrees: -10) == .c0to15)
        #expect(CutBucket(degrees: .nan) == .c0to15)
    }

    @Test func cutAngleHelper_straightIn_isZero() {
        let cue = Vec2(obj.x - 0.5, obj.y - 0.25)
        let pocket = obj + (obj - cue)
        #expect(abs(ShotFeatures.cutAngleDegrees(cue: cue, object: obj, target: pocket)) < 1.5)
    }

    @Test func cutAngleHelper_exactForConstructedCue() {
        for deg in stride(from: 0.0, through: 85, by: 5) {
            let cue = cuePosition(object: obj, pocket: footRight, degrees: deg, distance: 0.4)
            #expect(abs(ShotFeatures.cutAngleDegrees(cue: cue, object: obj, target: footRight) - deg) < 1e-6)
        }
    }

    @Test func cutAngleHelper_degenerateInputsAreFinite() {
        let a = ShotFeatures.cutAngleDegrees(cue: obj, object: obj, target: obj)
        #expect(a.isFinite && a >= 0)
    }
}

@Suite("ShotFeatures — distance buckets (fraction of playing length)")
struct DistanceBucketTests {
    @Test func thresholdsScaleWithTableLength() {
        let t = FeatureThresholds.standard
        #expect(DistanceBucket(path: 0.39 * spec7.length, tableLength: spec7.length, t) == .short)
        #expect(DistanceBucket(path: 0.40 * spec7.length, tableLength: spec7.length, t) == .mid)
        #expect(DistanceBucket(path: 0.89 * spec7.length, tableLength: spec7.length, t) == .mid)
        #expect(DistanceBucket(path: 0.90 * spec7.length, tableLength: spec7.length, t) == .long)
        let nine = TableSpec(size: .nineFoot).length
        #expect(DistanceBucket(path: 0.8, tableLength: spec7.length, t) == .short)
        #expect(DistanceBucket(path: 0.8, tableLength: nine, t) == .short)
        #expect(DistanceBucket(path: 1.0, tableLength: spec7.length, t) == .mid)
    }

    @Test func extract_shortMidLong() {
        // object→pocket ≈ 0.43 m; vary the cue distance.
        #expect(extractCut(10, distance: 0.1).distanceBucket == .short)
        #expect(extractCut(10, distance: 0.8).distanceBucket == .mid)
        #expect(extractCut(10, distance: 1.6).distanceBucket == .long)
    }
}

@Suite("ShotFeatures — pocket type")
struct PocketTypeTests {
    @Test func cornerAndSide() {
        #expect(PocketType(.footLeft) == .corner)
        #expect(PocketType(.headRight) == .corner)
        #expect(PocketType(.sideLeft) == .side)
        #expect(PocketType(.sideRight) == .side)
    }

    @Test func extract_sidePocketPot() {
        let o = Vec2(sideRight.x - 0.05, sideRight.y - 0.3)
        let cue = cuePosition(object: o, pocket: sideRight, degrees: 10, distance: 0.3)
        let pre = table([0: cue, 3: o])
        let f = ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [3]), trace: potTrace(3, .sideRight))
        #expect(f.pocketType == .side)
        #expect(f.kind == .plain)
    }

    @Test func extract_missUsesIntendedPocket() {
        let o = Vec2(sideRight.x - 0.05, sideRight.y - 0.3)
        let cue = cuePosition(object: o, pocket: sideRight, degrees: 10, distance: 0.3)
        let pre = table([0: cue, 3: o])
        let trace = ShotTraceSummary(events: [.ballBall(.cue, b(3)), .cushion(b(3))])
        let f = ShotFeatures.extract(pre: pre, post: pre, trace: trace,
                                     intent: ShotIntent(target: b(3), pocket: .sideRight))
        #expect(f.pocketType == .side)
        #expect(f.cutBucket == .c0to15)
    }

    @Test func extract_missWithoutIntent_infersEasiestPocket() {
        let cue = cuePosition(object: obj, pocket: footRight, degrees: 5, distance: 0.3)
        let pre = table([0: cue, 1: obj])
        let trace = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .cushion(b(1))])
        let f = ShotFeatures.extract(pre: pre, post: pre, trace: trace)
        #expect(f.pocketType == .corner)
        #expect(f.cutBucket == .c0to15)
    }
}

@Suite("ShotFeatures — shot kind (bank/combo/kick/rail/jump/safety)")
struct ShotKindTests {
    private let cue = cuePosition(object: obj, pocket: footRight, degrees: 20, distance: 0.4)

    @Test func plainPot() {
        let pre = table([0: cue, 1: obj])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: potTrace(1, .footRight)).kind == .plain)
    }

    @Test func bank_targetHitsCushionBeforePocket() {
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .cushion(b(1)), .pocket(b(1), .headRight)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .bank)
    }

    @Test func notBank_whenCushionHitBeforeContactByOtherBall() {
        let pre = table([0: cue, 1: obj, 2: Vec2(0.5, 0.5)])
        let t = ShotTraceSummary(events: [.cushion(b(2)), .ballBall(.cue, b(1)), .pocket(b(1), .footRight)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .plain)
    }

    @Test func kick_cueHitsCushionBeforeFirstContact() {
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.cushion(.cue), .ballBall(.cue, b(1)), .pocket(b(1), .footRight)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .kick)
    }

    @Test func cushionAfterContactIsNotKick() {
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .cushion(.cue), .pocket(b(1), .footRight)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .plain)
    }

    @Test func jump_cueAirborneBeforeFirstContact() {
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.airborne(.cue), .ballBall(.cue, b(1)), .pocket(b(1), .footRight)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .jump)
    }

    @Test func jumpBeatsKick() {
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.airborne(.cue), .cushion(.cue), .ballBall(.cue, b(1))])
        #expect(ShotFeatures.extract(pre: pre, post: pre, trace: t).kind == .jump)
    }

    @Test func airborneAfterContactIsNotJump() {
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .airborne(.cue), .pocket(b(1), .footRight)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .plain)
    }

    @Test func combo_inferredFromPocketedBallNotFirstContact() {
        let o2 = obj + (footRight - obj).normalized * 0.15
        let pre = table([0: cue, 1: obj, 2: o2])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .ballBall(b(1), b(2)), .pocket(b(2), .footRight)])
        let f = ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [2]), trace: t)
        #expect(f.kind == .combo)
        #expect(f.pocketType == .corner)
    }

    @Test func combo_fromIntentTargetDifferentFromFirstContact() {
        let o2 = obj + (footRight - obj).normalized * 0.15
        let pre = table([0: cue, 1: obj, 2: o2])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .ballBall(b(1), b(2))])
        let f = ShotFeatures.extract(pre: pre, post: pre, trace: t, intent: ShotIntent(target: b(2), pocket: .footRight))
        #expect(f.kind == .combo)
    }

    @Test func slopPocketOfUnstruckBallIsNotCombo() {
        // Ball 2 drops without any object-ball collision involving it (e.g. tracker noise): not a combo.
        let pre = table([0: cue, 1: obj, 2: Vec2(0.3, 0.3)])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .pocket(b(2), .headLeft)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [2]), trace: t).kind == .plain)
    }

    @Test func comboIntoBank_isCombo() {
        let o2 = obj + (footRight - obj).normalized * 0.15
        let pre = table([0: cue, 1: obj, 2: o2])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .ballBall(b(1), b(2)), .cushion(b(2)), .pocket(b(2), .footRight)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [2]), trace: t).kind == .combo)
    }

    @Test func rail_targetFrozenToCushion() {
        let o = Vec2(spec7.length - 0.6, spec7.width - R - 0.002)
        let c = Vec2(o.x - 0.5, o.y - 0.03)
        let pre = table([0: c, 1: o])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: potTrace(1, .footRight)).kind == .rail)
    }

    @Test func notRail_whenOneBallWidthOff() {
        let o = Vec2(spec7.length - 0.6, spec7.width - R - 2 * R)
        let c = Vec2(o.x - 0.5, o.y - 0.03)
        let pre = table([0: c, 1: o])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: potTrace(1, .footRight)).kind == .plain)
    }

    @Test(arguments: [0, 1, 2, 3])
    func rail_eachCushion(_ which: Int) {
        let L = spec7.length, W = spec7.width, d = R + 0.001
        let o = [Vec2(d, W / 3), Vec2(L - d, W / 3), Vec2(L / 3, d), Vec2(L / 3, W - d)][which]
        let pre = table([0: Vec2(L / 2, W / 2), 1: o])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .pocket(b(1), .headLeft)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .rail)
    }

    @Test func bankBeatsRail() {
        let o = Vec2(spec7.length - 0.6, spec7.width - R - 0.002)
        let pre = table([0: Vec2(o.x - 0.5, o.y - 0.3), 1: o])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1)), .cushion(b(1)), .pocket(b(1), .footLeft)])
        #expect(ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t).kind == .bank)
    }

    @Test func safetyIntentWins() {
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.cushion(.cue), .ballBall(.cue, b(1)), .cushion(b(1))])
        let f = ShotFeatures.extract(pre: pre, post: pre, trace: t, intent: ShotIntent(isSafety: true))
        #expect(f.kind == .safety)
    }

    @Test func noContactAtAll_fallsBackToNearestBall() {
        let far = Vec2(0.3, 0.3)
        let pre = table([0: cue, 1: obj, 2: far])
        let f = ShotFeatures.extract(pre: pre, post: pre, trace: ShotTraceSummary(events: []))
        // Nearest object ball to the cue is ball 1, cut 20° into its easiest pocket.
        #expect(f.kind == .plain)
        #expect(f.cutBucket == .c15to30)
    }

    @Test func emptyTable_returnsNeutralFeatures() {
        let pre = table([0: cue])
        let f = ShotFeatures.extract(pre: pre, post: pre, trace: ShotTraceSummary(events: []))
        #expect(f == ShotFeatures(cutBucket: .c0to15, distanceBucket: .short, pocketType: .corner, kind: .plain))
    }

    @Test func missingCueBall_returnsNeutralFeatures() {
        let pre = table([1: obj])
        let f = ShotFeatures.extract(pre: pre, post: pre, trace: potTrace(1, .footRight))
        #expect(f.kind == .plain && f.cutBucket == .c0to15)
    }

    @Test func pocketFromPostStateWhenTraceLacksPocketEvent() {
        // Tracker saw the drop (post state) but not which pocket: intended pocket is inferred.
        let pre = table([0: cue, 1: obj])
        let t = ShotTraceSummary(events: [.ballBall(.cue, b(1))])
        let f = ShotFeatures.extract(pre: pre, post: afterPocketing(pre, [1]), trace: t)
        #expect(f.pocketType == .corner)
        #expect(f.kind == .plain)
    }
}

@Suite("ShotFeatures — persistence format")
struct ShotFeaturesCodingTests {
    @Test func rawValuesMatchPersistedStoredShotFeatures() {
        #expect(CutBucket.allCases.map(\.rawValue) == ["c0to15", "c15to30", "c30to45", "c45to60", "c60plus"])
        #expect(DistanceBucket.allCases.map(\.rawValue) == ["short", "mid", "long"])
        #expect(PocketType.allCases.map(\.rawValue) == ["corner", "side"])
        #expect(ShotKind.allCases.map(\.rawValue) == ["plain", "bank", "combo", "kick", "rail", "jump", "safety"])
    }

    @Test func decodesTheAppsStoredJSON() throws {
        let json = #"{"cutBucket":"c15to30","distanceBucket":"mid","kind":"bank","pocketType":"corner"}"#
        let f = try JSONDecoder().decode(ShotFeatures.self, from: Data(json.utf8))
        #expect(f == ShotFeatures(cutBucket: .c15to30, distanceBucket: .mid, pocketType: .corner, kind: .bank))
    }

    @Test func roundTrips() throws {
        let f = ShotFeatures(cutBucket: .c60plus, distanceBucket: .long, pocketType: .side, kind: .jump)
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        let data = try e.encode(f)
        #expect(String(decoding: data, as: UTF8.self) ==
                #"{"cutBucket":"c60plus","distanceBucket":"long","kind":"jump","pocketType":"side"}"#)
        #expect(try JSONDecoder().decode(ShotFeatures.self, from: data) == f)
    }

    @Test func traceSummaryRoundTrips() throws {
        let t = ShotTraceSummary(events: [.airborne(.cue), .cushion(.cue), .ballBall(.cue, b(3)), .pocket(b(3), .sideLeft)])
        #expect(try JSONDecoder().decode(ShotTraceSummary.self, from: JSONEncoder().encode(t)) == t)
    }
}
