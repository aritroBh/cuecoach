import Foundation
import UIKit
import Testing
@testable import CueCoach

// Coordinator follow-ups after r4: bench consent only through the consent flow; expiry on launch / foreground.

@MainActor @Suite(.serialized) struct BenchConsentFlowTests {
    @Test func onlyAGrantRecordedByTheFlowIsAccepted() {
        let bench = FaceBenchmarkSession(modelID: "m")
        let grant = FaceBenchConsentFlow.grant(agreedAt: .now)
        #expect(FaceBenchConsentFlow.isGranted(grant))
        #expect(bench.addSubject([Synth.axis(1, model: "m")], consent: grant) != nil)
        // Withdrawing the grant makes it unusable for any further capture.
        FaceBenchConsentFlow.withdraw(grant)
        #expect(!FaceBenchConsentFlow.isGranted(grant))
        #expect(bench.addSubject([Synth.axis(2, model: "m")], consent: grant) == nil)
    }

    @Test func expiredRunIsPurgedWhenTheAppComesToTheForeground() {
        let old = Date(timeIntervalSince1970: 0)
        let bench = FaceBenchmarkSession(modelID: "m", startedAt: old)
        _ = bench.addSubject([Synth.axis(1, model: "m")], consent: FaceBenchConsentFlow.grant(agreedAt: old), now: old)
        #expect(bench.heldEmbeddingCount == 1)          // raw count: reading it does not expire anything
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(bench.heldEmbeddingCount == 0)
    }

    @Test func expiredRunIsPurgedOnLaunch() {
        let old = Date(timeIntervalSince1970: 0)
        let bench = FaceBenchmarkSession(modelID: "m", startedAt: old)
        _ = bench.addSubject([Synth.axis(1, model: "m")], consent: FaceBenchConsentFlow.grant(agreedAt: old), now: old)
        NotificationCenter.default.post(name: UIApplication.didFinishLaunchingNotification, object: nil)
        #expect(bench.heldEmbeddingCount == 0)
    }

    @Test func aFreshRunSurvivesForeground() {
        let bench = FaceBenchmarkSession(modelID: "m")
        _ = bench.addSubject([Synth.axis(1, model: "m")], consent: FaceBenchConsentFlow.grant(agreedAt: .now))
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(bench.heldEmbeddingCount == 1)
    }
}

// Codex r5: one grant = one volunteer (no pseudo-subjects across calibration/report); FAR gets a bound too.
@MainActor @Suite struct Round5FollowUpTests {
    @Test func oneGrantIsOneVolunteerEvenAcrossCaptures() {
        let bench = FaceBenchmarkSession(modelID: "m")
        let g = FaceBenchConsentFlow.grant()
        let first = bench.addSubject([Synth.axis(1, model: "m")], consent: g)
        let again = bench.addSubject([Synth.axis(1, model: "m")], consent: g)
        #expect(first != nil && again == first)        // same volunteer code, appended
        #expect(bench.subjectCount == 1 && bench.embeddingCount == 2)
    }

    @Test func passRecordsAHeldOutFARBound() {
        guard case .pass(let r) = FaceBenchmark.evaluate(subjects: HeldOutShipGateTests.subjects(20, spread: 0.05), modelID: "m") else {
            Issue.record("expected pass"); return
        }
        #expect(r.farUpper95 >= r.farObserved && r.farUpper95 <= 1)
    }
}

// Codex r6: FAR bound from a volunteer-level bootstrap that recomputes impostor pairs among resampled volunteers.
@Suite struct FARBootstrapTests {
    @Test func boundDoesNotDependOnVolunteerOrder() {
        let sets = HeldOutShipGateTests.subjects(20, spread: 0.3)
        let t = 0.05
        let a = FaceBenchmark.farUpperBootstrap(sets, threshold: t)
        let b = FaceBenchmark.farUpperBootstrap(Array(sets.reversed()), threshold: t)
        let c = FaceBenchmark.farUpperBootstrap(sets.enumerated().sorted { ($0.offset * 7) % 20 < ($1.offset * 7) % 20 }.map(\.element), threshold: t)
        #expect(a == b && a == c)
        #expect(a > 0)
    }

    @Test func aClusteredImpostorWidensTheBoundWellBeyondWilson() {
        // 20 volunteers, 144 comparisons per pair; every false accept involves volunteer 0.
        let n = 20
        var m = [[(fa: Int, n: Int)]](repeating: [(fa: Int, n: Int)](repeating: (0, 144), count: n), count: n)
        for j in 1..<n { m[0][j] = (2, 144); m[j][0] = (2, 144) }
        let boot = FaceBenchmark.farUpperBootstrap(matrix: m)
        let fa = 2 * (n - 1), total = n * (n - 1) / 2 * 144
        let wilson = FaceBenchmark.wilsonUpper(successes: fa, n: total)
        #expect(boot > 1.5 * wilson, "bootstrap \(boot) vs Wilson \(wilson)")
    }

    @Test func copiesOfOneVolunteerNeverFormImpostorPairs() {
        // Only one volunteer: no impostor pairs in any resample → FAR bound 0 (and no crash).
        #expect(FaceBenchmark.farUpperBootstrap(matrix: [[(0, 0)]]) == 0)
    }
}

/// Fix round (review finding 7): the ship-gate verdict can't depend on Dictionary order (per-process hash seed).
@MainActor @Suite(.serialized) struct BenchmarkOrderTests {
    static func runInOrder(_ order: [Int], _ subs: [[Embedding]], at t0: Date) -> FaceBenchmark.Verdict {
        let store = FaceShipGateStore(key: "test.gate.\(UUID().uuidString)")
        defer { store.clear() }
        let s = FaceBenchmarkSession(modelID: "m", startedAt: t0)
        for i in order { s.addSubject(subs[i], consent: FaceBenchConsentFlow.grant(agreedAt: t0), now: t0) }
        return s.finish(store: store, now: t0)
    }

    /// passedAt is the wall clock at finish; compare everything else.
    static func stable(_ v: FaceBenchmark.Verdict) -> FaceBenchmark.Verdict {
        guard case .pass(var r) = v else { return v }
        r.passedAt = .distantPast
        return .pass(r)
    }

    @Test func sameVolunteersInAnyOrderGiveTheSameVerdictAndReport() {
        let subs = HeldOutShipGateTests.subjects(20, spread: 0.05)
        let t0 = Date()
        let forward = Self.runInOrder(Array(0..<20), subs, at: t0)
        let backward = Self.runInOrder(Array((0..<20).reversed()), subs, at: t0)
        let interleaved = Self.runInOrder(Array(stride(from: 1, to: 20, by: 2)) + Array(stride(from: 0, to: 20, by: 2)), subs, at: t0)
        #expect(Self.stable(forward) == Self.stable(backward))
        #expect(Self.stable(forward) == Self.stable(interleaved))
        // Several runs of the same order also agree (each run re-keys volunteers with fresh UUIDs).
        for _ in 0..<3 { #expect(Self.stable(Self.runInOrder(Array(0..<20), subs, at: t0)) == Self.stable(forward)) }
    }
}
