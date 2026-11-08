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
