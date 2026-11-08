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
