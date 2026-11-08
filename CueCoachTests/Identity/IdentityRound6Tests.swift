import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

// Codex r4 findings, fixed test-first.

@Suite struct Round6FaceTests {
    @Test func threeDifferentPeopleNeverPassTheSameFaceCheck() {
        // Mutually orthogonal faces each score ~0.58 against their mean; pairwise they are 0.
        let three = [Synth.axis(1, model: faceModel), Synth.axis(2, model: faceModel), Synth.axis(3, model: faceModel)]
        #expect(!RecognitionRegistrar.samePerson(three))
        #expect(RecognitionRegistrar.samePerson([Synth.axis(1, model: faceModel), Synth.near(1, cos: 0.8, other: 2, model: faceModel),
                                                 Synth.near(1, cos: 0.8, other: 3, model: faceModel)]))
    }

    @Test func passMeasuresHeldOutFARAndBootstrapBounds() {
        guard case .pass(let r) = FaceBenchmark.evaluate(subjects: HeldOutShipGateTests.subjects(20, spread: 0.05), modelID: "m") else {
            Issue.record("expected pass"); return
        }
        #expect(r.farObserved <= r.far)
        #expect(r.fpirUpper95 >= r.fpir && r.tarLower95 <= r.tar)
        #expect(r.meetsD28)
    }

    @Test func subjectBootstrapIsDeterministicAndBracketsThePointEstimate() {
        // Per-subject (hits, n): one subject is all misses.
        let groups = [(10, 10), (10, 10), (0, 10), (10, 10), (10, 10)]
        let (lo, hi) = FaceBenchmark.bootstrapRate(groups)
        #expect(lo <= 0.8 && hi >= 0.8 && lo < hi)
        #expect(FaceBenchmark.bootstrapRate(groups) == (lo, hi))
    }

    @Test func aRecordThatDoesNotMeetD28NeverOpensFaceMatching() async {
        var bad = FaceShipGateRecord.testPass(modelID: faceModel); bad.tar = 0.5
        #expect(!bad.meetsD28)
        let snap = IdentitySnapshot(roster: IdentityRoster(entries: [RosterEntry(playerID: Synth.a, consent: .init(clothes: false, face: true))]),
                                    appearanceGallery: [:], faceGallery: [Synth.a: [Synth.axis(2, model: faceModel)]])
        let people = [ObservedPerson(box: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.25),
                                     joints: BodyJoints(points: [.neck: CGPoint(x: 0.45, y: 0.42), .root: CGPoint(x: 0.25, y: 0.40),
                                                                 .leftWrist: CGPoint(x: 0.49, y: 0.31)]),
                                     face: Synth.axis(2, model: faceModel), faceQuality: 0.9)]
        let a = FakeAnalyzer(script: [1: people])
        _ = await VisionShooterIdentifier(analyzer: a, faceMatching: .shooterOnly, faceGate: bad)
            .identify(StrokeWindow(frames: [IdentityFrame(image: testImage(width: 1), cueBall: CGPoint(x: 0.5, y: 0.3))]),
                      snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(a.wants.allSatisfy { !$0.face })
    }
}

@MainActor @Suite struct Round6RegistrationTests {
    @Test func cancelledRegistrationNeverWrites() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner(); stack.competitiveContext.insert(owner); try stack.competitiveContext.save()
        // The extractor cancels its own task on the last image; earlier images already give enough samples.
        final class CancelOnLast: EmbeddingExtracting, @unchecked Sendable {
            let modelID = bodyModel; var n = 0
            func embedding(of image: CGImage) async throws -> Embedding {
                n += 1
                if n == 4 { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
                return Synth.axis(5, model: bodyModel)
            }
        }
        let capture = RegistrationCapture(faceImages: [], bodyImages: (0..<4).map { _ in testImage(width: 5) })
        let reg = RecognitionRegistrar(stack: stack, face: nil, body: CancelOnLast())
        let t = Task { try await reg.register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: false), agreedAt: .now),
                                              capture: capture) }
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(owner.recognition == nil)
    }
}
