import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

// Codex round-2 BLOCK fixes (identity-r2-codex.md): consent leaks, off-team guests, explicit unknown,
// epoch on roster growth, cancellation on revoke, re-consent at session start, negative signal after a correction.

private func roster(_ entries: [(UUID, RecognitionConsent)], guests: [UUID] = []) -> IdentityRoster {
    IdentityRoster(entries: entries.map { RosterEntry(playerID: $0.0, consent: $0.1) }
                   + guests.map { RosterEntry(playerID: $0, consent: .none, isGuest: true) })
}

private func shooter(clothes: [UUID: Double] = [:], face: [UUID: Double] = [:]) -> TrackEvidence {
    TrackEvidence(trackID: 1, poseScore: 0.95, distanceToCueBall: 0.05, appearanceSimilarity: clothes, faceSimilarity: face)
}

private let clothes = RecognitionConsent(clothes: true, face: false)
private let cue = CGPoint(x: 0.5, y: 0.3)
private let shooterJoints = BodyJoints(points: [.neck: CGPoint(x: 0.45, y: 0.42), .root: CGPoint(x: 0.25, y: 0.40),
                                                .leftWrist: CGPoint(x: 0.49, y: 0.31)])
private let shooterBox = CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.25)

private func window(_ frames: Int) -> StrokeWindow {
    StrokeWindow(frames: (1...frames).map { IdentityFrame(image: testImage(width: $0), cueBall: cue) })
}

private func stored(body: [Embedding]? = nil, face: [Embedding]? = nil, version: Int = IdentityConsentTerms.current) -> StoredRecognitionTemplates {
    StoredRecognitionTemplates(faceEmbedding: face.map { try! EmbeddingCodec.encode($0) },
                               appearanceEmbedding: body.map { try! EmbeddingCodec.encode($0) },
                               optedInAt: Date(timeIntervalSince1970: 0), version: version)
}

// MARK: - Attribution: explicit unknown, off-team guests, ties

@Suite struct UnknownAttributionTests {
    let attributor = ShooterAttributor()

    @Test func offTeamLookalikeGuestIsNeverAutoAttributedToARegisteredPlayer() {
        // r2 BLOCKER 2: A expected, consenting teammate C in the turn, off-team guest B (A's shirt) shoots.
        let r = roster([(Synth.a, clothes), (Synth.c, clothes)], guests: [Synth.b])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a, teamInTurn: [Synth.a, Synth.c])
        let out = attributor.attribute(views: [[shooter(clothes: [Synth.a: 0.97, Synth.c: 0.1])]], context: ctx)
        #expect(out.source != .auto)
        #expect(out.playerID == nil && out.needsConfirmation)
    }

    @Test func offTeamNonConsentedPlayerAlsoBlocksAuto() {
        // Every person who could be at the cue ball competes, not just the team in turn.
        let r = roster([(Synth.a, clothes), (Synth.c, clothes), (Synth.b, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a, teamInTurn: [Synth.a, Synth.c])
        let out = attributor.attribute(views: [[shooter(clothes: [Synth.a: 0.97, Synth.c: 0.1])]], context: ctx)
        #expect(out.source != .auto)
    }

    @Test func guestTieIsUnknownNotASilentTurnOrderCredit() {
        // r2 MAJOR: a gated guest ties A's clothing match → ask, credit nobody.
        let r = roster([(Synth.a, clothes)], guests: [Synth.d])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[shooter(clothes: [Synth.a: 0.95])]], context: ctx)
        #expect(out.source == .unknown && out.playerID == nil && out.needsConfirmation)
        #expect(out.suggestedPlayerID == Synth.a)
    }

    @Test func registeredExpectedShooterWithAGuestAtTheTableAndNoEvidenceAsks() {
        // A guest could be the one at the cue ball unseen: never silently credit a registered profile.
        let r = roster([(Synth.a, .none), (Synth.b, .none)], guests: [Synth.d])
        let out = attributor.attribute(views: [], context: AttributionContext(roster: r, expectedShooter: Synth.a))
        #expect(out.source == .unknown && out.playerID == nil)
    }

    @Test func guestsOwnTurnWithoutEvidenceIsTheGuest() {
        let r = roster([(Synth.a, .none)], guests: [Synth.d])
        let out = attributor.attribute(views: [], context: AttributionContext(roster: r, expectedShooter: Synth.d))
        #expect(out.playerID == Synth.d && out.source == .turnOrder && !out.needsConfirmation)
    }

    @Test func registeredOnlyTableWithoutEvidenceIsSilentTurnOrder() {
        let r = roster([(Synth.a, .none), (Synth.b, .none)])
        let out = attributor.attribute(views: [], context: AttributionContext(roster: r, expectedShooter: Synth.b))
        #expect(out.playerID == Synth.b && out.source == .turnOrder && !out.needsConfirmation)
    }

    @Test func tieBetweenTwoRecognisablePlayersAsks() {
        let r = roster([(Synth.a, clothes), (Synth.b, clothes)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[shooter(clothes: [Synth.a: 0.9, Synth.b: 0.9])]], context: ctx)
        #expect(out.source == .unknown && out.playerID == nil)
    }

    @Test func consentedLookalikeOfAnUnmodelledExpectedShooterAsksAndNeverCreditsTheLookalike() {
        // S1 tightened: B (no consent) on B's turn looks exactly like consented A → a real tie: ask.
        let r = roster([(Synth.a, clothes), (Synth.b, .none)])
        let out = attributor.attribute(views: [[shooter(clothes: [Synth.a: 0.98])]],
                                       context: AttributionContext(roster: r, expectedShooter: Synth.b))
        #expect(out.playerID != Synth.a)
        #expect(out.source == .unknown)
    }

    @Test func expectedOutsideRosterIsUnknown() {
        let out = attributor.attribute(views: [], context: AttributionContext(roster: roster([]), expectedShooter: Synth.c))
        #expect(out == .unknown(suggested: Synth.c, confidence: 0, shooterTrackID: nil))
    }

    @Test func identityFaceCanAutoAgainstAnUnmodelledRegisteredPlayer() {
        // An identity-trained model (small lookalike rate from the benchmark) can separate A from "someone else"
        // (here: non-consenting C). With a guest at the table it never autos (IdentityRound4Tests).
        let r = roster([(Synth.a, .init(clothes: false, face: true)), (Synth.c, .none)])
        var trained = ShooterAttributor(); trained.parameters.face = ShooterAttributionTests.identityFace
        let out = trained.attribute(views: [[shooter(face: [Synth.a: 0.95])]],
                                    context: AttributionContext(roster: r, expectedShooter: Synth.a))
        #expect(out.playerID == Synth.a && out.source == .auto)
    }

    @Test func unknownStoresNoSource() {
        #expect(Attribution.unknown(suggested: Synth.a, confidence: 0, shooterTrackID: nil).storedSource == nil)
        #expect(Attribution(playerID: Synth.a, source: .auto, confidence: 1, shooterTrackID: 1).storedSource == .auto)
    }
}

// MARK: - Learning: nothing is embedded or learned from a turn-order guess

/// Suspends on frame 1 until released; counts calls and what embeddings were requested.
final class GatedAnalyzer: PersonAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _appearanceRequests = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var didStart = false
    let people: [ObservedPerson]
    init(people: [ObservedPerson]) { self.people = people }
    var calls: Int { lock.withLock { _calls } }
    var appearanceRequests: Int { lock.withLock { _appearanceRequests } }

    func waitUntilStarted() async {
        await withCheckedContinuation { c in
            let now = lock.withLock { () -> Bool in if didStart { return true }; started = c; return false }
            if now { c.resume() }
        }
    }
    func open() { let r = lock.withLock { () -> CheckedContinuation<Void, Never>? in let r = release; release = nil; return r }; r?.resume() }

    func people(in image: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson] {
        let first = lock.withLock { () -> Bool in _calls += 1; if wants.appearance { _appearanceRequests += 1 }; return _calls == 1 }
        if first {
            await withCheckedContinuation { c in
                let s = lock.withLock { () -> CheckedContinuation<Void, Never>? in release = c; didStart = true; let s = started; started = nil; return s }
                s?.resume()
            }
        }
        return people.map { ObservedPerson(box: $0.box, joints: $0.joints, appearance: wants.appearance ? $0.appearance : nil) }
    }
}

@Suite struct ConsentLeakTests {
    @Test func consentedExpectedShooterWithEmptyGalleryIsNeverEmbedded() async {
        // r2 BLOCKER 1: A consented but has no usable template; a guest shoots on A's turn. Nobody is embedded.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(6, model: bodyModel))]
        let snap = IdentitySnapshot(roster: IdentityRoster(entries: [RosterEntry(playerID: Synth.a, consent: clothes),
                                                                     RosterEntry(playerID: Synth.d, isGuest: true)]),
                                    appearanceGallery: [:], faceGallery: [:])
        let analyzer = FakeAnalyzer(script: [1: people, 2: people])
        let out = await VisionShooterIdentifier(analyzer: analyzer)
            .identify(window(2), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(analyzer.wants.allSatisfy { !$0.appearance && !$0.face })
        #expect(out.shooterAppearance == nil)
    }

    @MainActor @Test func ownTurnSampleNeverExtendsATemplateWithoutATap() async {
        // Turn order is a guess, never a label: the template stays exactly the registration seed.
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)])),
                                          (Synth.b, stored(body: [Synth.axis(2, model: bodyModel)]))],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let sample = Synth.near(1, cos: 0.9, other: 7, model: bodyModel)
        s.record(shot: UUID(), ShooterIdentification(attribution: Attribution(playerID: Synth.a, source: .turnOrder, confidence: 0.8,
                                                                              shooterTrackID: 1), shooterAppearance: sample),
                 expectedShooter: Synth.a)
        s.record(shot: UUID(), ShooterIdentification(attribution: Attribution(playerID: Synth.a, source: .auto, confidence: 0.95,
                                                                              shooterTrackID: 1), shooterAppearance: sample),
                 expectedShooter: Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a] == [Synth.axis(1, model: bodyModel)])
    }

    @MainActor @Test func aConfirmingTapTeachesTheTappedConsentedPlayer() async {
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)])),
                                          (Synth.b, stored(body: [Synth.axis(2, model: bodyModel)]))],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let sample = Synth.near(1, cos: 0.9, other: 7, model: bodyModel)
        let shot = UUID()
        s.record(shot: shot, ShooterIdentification(attribution: .unknown(suggested: Synth.a, confidence: 0.5, shooterTrackID: 1),
                                                   shooterAppearance: sample), expectedShooter: Synth.a)
        _ = s.correct(shot: shot, to: Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a]?.contains(sample.normalised!) == true)
    }

    @MainActor @Test func tapToAGuestTeachesNobodyAndDropsTheVector() async {
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)]))], guests: [Synth.d],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let shot = UUID()
        s.record(shot: shot, ShooterIdentification(attribution: .unknown(suggested: Synth.a, confidence: 0.5, shooterTrackID: 1),
                                                   shooterAppearance: Synth.near(1, cos: 0.9, other: 7, model: bodyModel)),
                 expectedShooter: Synth.a)
        _ = s.correct(shot: shot, to: Synth.d)
        #expect(s.snapshot().appearanceGallery[Synth.a] == [Synth.axis(1, model: bodyModel)])
        #expect(s.snapshot().appearanceGallery[Synth.d] == nil)
        #expect(s.pendingSampleCount == 0)
    }
}

// MARK: - Session lifecycle: epoch, cancellation, re-consent, retry exhaustion

/// Identifier that runs `during` on its first call (inside the await), then reports the roster it was given.
struct MutatingIdentifier: ShooterIdentifier {
    let calls: Counter
    let during: @MainActor @Sendable () -> Void
    final class Counter: @unchecked Sendable { var n = 0; var rosters: [Int] = [] }
    func identify(_ window: StrokeWindow, snapshot: IdentitySnapshot, expectedShooter: UUID,
                  teamInTurn: Set<UUID>?) async -> ShooterIdentification {
        calls.n += 1
        calls.rosters.append(snapshot.roster.entries.count)
        if calls.n == 1 { await during() }
        return ShooterIdentification(attribution: Attribution(playerID: expectedShooter, source: .auto, confidence: 0.9, shooterTrackID: 1),
                                     shooterAppearance: nil)
    }
}

@MainActor @Suite struct SessionLifecycleTests {
    @Test func guestJoiningDuringAnalysisInvalidatesTheResult() async {
        let s = IdentitySession(players: [(Synth.a, nil)], faceModelID: faceModel, bodyModelID: bodyModel)
        let c = MutatingIdentifier.Counter()
        _ = await s.identifyShot(UUID(), window: window(1), expectedShooter: Synth.a, teamInTurn: nil,
                                 using: MutatingIdentifier(calls: c, during: { s.addGuest(Synth.d) }))
        #expect(c.n == 2 && c.rosters == [1, 2])
    }

    @Test func playerJoiningDuringAnalysisInvalidatesTheResult() async {
        let s = IdentitySession(players: [(Synth.a, nil)], faceModelID: faceModel, bodyModelID: bodyModel)
        let c = MutatingIdentifier.Counter()
        _ = await s.identifyShot(UUID(), window: window(1), expectedShooter: Synth.a, teamInTurn: nil,
                                 using: MutatingIdentifier(calls: c, during: { s.addPlayer(id: Synth.b, stored: nil) }))
        #expect(c.n == 2)
    }

    @Test func retryExhaustionIsUnknown() async {
        let s = IdentitySession(players: [(Synth.a, nil), (Synth.b, nil)], faceModelID: faceModel, bodyModelID: bodyModel)
        struct Churn: ShooterIdentifier {
            let s: IdentitySession
            func identify(_ w: StrokeWindow, snapshot: IdentitySnapshot, expectedShooter: UUID, teamInTurn: Set<UUID>?) async -> ShooterIdentification {
                await MainActor.run { s.addGuest(UUID()) }
                return ShooterIdentification(attribution: Attribution(playerID: expectedShooter, source: .auto, confidence: 1, shooterTrackID: 1),
                                             shooterAppearance: nil)
            }
        }
        let att = await s.identifyShot(UUID(), window: window(1), expectedShooter: Synth.a, teamInTurn: nil, using: Churn(s: s))
        #expect(att.needsConfirmation && att.playerID == nil)
    }

    @Test func revokeCancelsInFlightProcessing() async {
        // r2 MAJOR: after revoke no further frames are analysed (no more embeddings computed).
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)])),
                                          (Synth.b, stored(body: [Synth.axis(2, model: bodyModel)]))],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(1, model: bodyModel))]
        let analyzer = GatedAnalyzer(people: people)
        let id = VisionShooterIdentifier(analyzer: analyzer)
        let task = Task { await s.identifyShot(UUID(), window: window(6), expectedShooter: Synth.a, teamInTurn: nil, using: id) }
        await analyzer.waitUntilStarted()
        s.revoke(Synth.a)
        s.revoke(Synth.b)
        analyzer.open()
        _ = await task.value
        // Frame 1 of the cancelled run, then the retry runs on the revoked snapshot: no appearance requested again.
        #expect(analyzer.appearanceRequests == 1)
        #expect(analyzer.calls < 6 + 6)
    }

    @Test func outdatedConsentIsNotLoadedAndIsFlagged() {
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)], version: 0))],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(s.roster.consent(of: Synth.a) == .none)
        #expect(s.snapshot().appearanceGallery.isEmpty)
        #expect(s.needsReconsent == [Synth.a])
    }

    @Test func modelChangeMakesTheWholeRowUnusableUntilReconsent() {
        // Face templates from another model → re-consent; even the clothes templates are not loaded meanwhile.
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)], face: [Synth.axis(2, model: "old.face")]))],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(s.roster.consent(of: Synth.a) == .none)
        #expect(s.snapshot().appearanceGallery.isEmpty && s.snapshot().faceGallery.isEmpty)
        #expect(s.needsReconsent == [Synth.a])
    }
}

// MARK: - S9: a correction is a negative signal against the wrongly chosen template

@MainActor @Suite struct NegativeSignalTests {
    @Test func correctionStopsTheWrongTemplateClaimingTheSameLook() async {
        // A consented; teammate B (no consent) wears nearly A's shirt. B's shot got credited to A; a tap fixes it.
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)])), (Synth.b, nil)],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let bLook = Synth.near(1, cos: 0.93, other: 8, model: bodyModel)
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: bLook)]
        let first = UUID()
        s.record(shot: first, ShooterIdentification(
            attribution: Attribution(playerID: Synth.a, source: .auto, confidence: 0.9, shooterTrackID: 1),
            shooterAppearance: bLook,
            evidence: [TrackEvidence(trackID: 1, poseScore: 0.95, distanceToCueBall: 0.05, appearanceSimilarity: [Synth.a: 0.93])]),
            expectedShooter: Synth.a)
        _ = s.correct(shot: first, to: Synth.b)
        #expect(s.snapshot().appearanceClaimCeiling[Synth.a] == 0.93)
        // Same look again on A's turn: A's template may no longer claim it.
        let out = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]))
            .identify(window(1), snapshot: s.snapshot(), expectedShooter: Synth.a, teamInTurn: nil)
        #expect(out.attribution.source != .auto)
        #expect(out.evidence.first?.appearanceSimilarity[Synth.a] == nil)
        // A's own clearly-matching look still counts.
        let aPeople = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.near(1, cos: 0.99, other: 8, model: bodyModel))]
        let own = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: aPeople]))
            .identify(window(1), snapshot: s.snapshot(), expectedShooter: Synth.a, teamInTurn: nil)
        #expect(own.evidence.first?.appearanceSimilarity[Synth.a] != nil)
    }

    @Test func revokeClearsTheCeiling() {
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)])), (Synth.b, nil)],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let shot = UUID()
        s.record(shot: shot, ShooterIdentification(
            attribution: Attribution(playerID: Synth.a, source: .auto, confidence: 0.9, shooterTrackID: 1), shooterAppearance: nil,
            evidence: [TrackEvidence(trackID: 1, poseScore: 0.95, distanceToCueBall: 0.05, appearanceSimilarity: [Synth.a: 0.9])]),
            expectedShooter: Synth.a)
        _ = s.correct(shot: shot, to: Synth.b)
        s.revoke(Synth.a)
        #expect(s.snapshot().appearanceClaimCeiling[Synth.a] == nil)
    }
}
