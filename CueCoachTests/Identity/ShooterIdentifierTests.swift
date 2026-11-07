import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

/// Fake Vision: returns scripted people per frame (keyed by frame index via image width). Records what it was asked.
final class FakeAnalyzer: PersonAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var _wants: [AnalysisWants] = []
    var wants: [AnalysisWants] { lock.withLock { _wants } }
    let script: [Int: [ObservedPerson]]
    let failing: Set<Int>
    init(script: [Int: [ObservedPerson]], failing: Set<Int> = []) { self.script = script; self.failing = failing }
    func people(in image: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson] {
        lock.withLock { _wants.append(wants) }
        if failing.contains(image.width) { throw CancellationError() }
        return (script[image.width] ?? []).map {
            ObservedPerson(box: $0.box, joints: $0.joints, appearance: wants.appearance ? $0.appearance : nil,
                           face: wants.face ? $0.face : nil, faceQuality: wants.face ? $0.faceQuality : nil)
        }
    }
}

private let cue = CGPoint(x: 0.5, y: 0.3)
private let shooterJoints = BodyJoints(points: [.neck: CGPoint(x: 0.45, y: 0.42), .root: CGPoint(x: 0.25, y: 0.40),
                                                .leftWrist: CGPoint(x: 0.49, y: 0.31)])
private let standingJoints = BodyJoints(points: [.neck: CGPoint(x: 0.85, y: 0.7), .root: CGPoint(x: 0.85, y: 0.45),
                                                 .leftWrist: CGPoint(x: 0.83, y: 0.5)])
private let shooterBox = CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.25)
private let standerBox = CGRect(x: 0.78, y: 0.3, width: 0.14, height: 0.5)

private func window(_ frames: Int) -> StrokeWindow {
    StrokeWindow(frames: (1...frames).map { IdentityFrame(image: testImage(width: $0), cueBall: cue) })
}

private func snapshot(clothes: [UUID: Embedding], roster entries: [RosterEntry]) -> IdentitySnapshot {
    IdentitySnapshot(roster: IdentityRoster(entries: entries), appearanceGallery: clothes.mapValues { [$0] }, faceGallery: [:])
}

@Suite struct ShooterIdentifierTests {
    @Test func identifiesConsentedShooterByClothesAtTheCueBall() async {
        // B (shooting, bent over at the cue ball) wears axis-1 clothes; A stands nearby wearing axis-0.
        let people: [ObservedPerson] = [
            ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.near(1, cos: 0.95, other: 9, model: bodyModel)),
            ObservedPerson(box: standerBox, joints: standingJoints, appearance: Synth.near(0, cos: 0.95, other: 9, model: bodyModel)),
        ]
        let analyzer = FakeAnalyzer(script: [1: people, 2: people, 3: people])
        let snap = snapshot(clothes: [Synth.a: Synth.axis(0, model: bodyModel), Synth.b: Synth.axis(1, model: bodyModel)],
                            roster: [RosterEntry(playerID: Synth.a, consent: .init(clothes: true, face: false)),
                                     RosterEntry(playerID: Synth.b, consent: .init(clothes: true, face: false))])
        let id = VisionShooterIdentifier(analyzer: analyzer)
        let out = await id.identify(window(3), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(out.attribution.playerID == Synth.b)
        #expect(out.attribution.source == .auto)
        #expect(out.shooterAppearance?.cosine(Synth.axis(1, model: bodyModel)) ?? 0 > 0.9)
    }

    @Test func withoutAnyConsentNoEmbeddingIsEverRequested() async {
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints,
                                     appearance: Synth.axis(1, model: bodyModel), face: Synth.axis(1, model: faceModel))]
        let analyzer = FakeAnalyzer(script: [1: people, 2: people])
        let snap = snapshot(clothes: [:], roster: [RosterEntry(playerID: Synth.a), RosterEntry(playerID: Synth.b)])
        let out = await VisionShooterIdentifier(analyzer: analyzer)
            .identify(window(2), snapshot: snap, expectedShooter: Synth.b, teamInTurn: nil)
        #expect(analyzer.wants.allSatisfy { !$0.appearance && !$0.face })
        #expect(out.attribution.playerID == Synth.b && out.attribution.source == .turnOrder)
        #expect(out.shooterAppearance == nil)
    }

    @Test func galleryEntriesForNonConsentedPlayersAreIgnored() async {
        // Defensive: a snapshot that (wrongly) carries a template for a non-consented player must not use it.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(1, model: bodyModel))]
        let snap = snapshot(clothes: [Synth.b: Synth.axis(1, model: bodyModel)],
                            roster: [RosterEntry(playerID: Synth.a, consent: .init(clothes: true, face: false)), RosterEntry(playerID: Synth.b)])
        let out = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]))
            .identify(window(1), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(out.evidence.allSatisfy { $0.appearanceSimilarity[Synth.b] == nil })
    }

    @Test func shooterSampleIsDroppedWhenAttributedPlayerDidNotConsent() async {
        // A consented, C didn't. C is expected and the shooting track doesn't match A → turn order → C, sample dropped.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(5, model: bodyModel))]
        let snap = snapshot(clothes: [Synth.a: Synth.axis(0, model: bodyModel)],
                            roster: [RosterEntry(playerID: Synth.a, consent: .init(clothes: true, face: false)), RosterEntry(playerID: Synth.c)])
        let out = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]))
            .identify(window(1), snapshot: snap, expectedShooter: Synth.c, teamInTurn: nil)
        #expect(out.attribution.playerID == Synth.c)
        #expect(out.shooterAppearance == nil)
    }

    @Test func analyzerFailuresFallBackToTurnOrder() async {
        let snap = snapshot(clothes: [Synth.a: Synth.axis(0, model: bodyModel)],
                            roster: [RosterEntry(playerID: Synth.a, consent: .init(clothes: true, face: false)), RosterEntry(playerID: Synth.b)])
        let out = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [:], failing: [1, 2]))
            .identify(window(2), snapshot: snap, expectedShooter: Synth.b, teamInTurn: nil)
        #expect(out.attribution == Attribution(playerID: Synth.b, source: .turnOrder, confidence: out.attribution.confidence, shooterTrackID: nil))
    }

    @Test func strokeTimeNeverEmbedsFacesEvenWithFaceConsent() async {
        // Q10 is open (default: no). Stroke-time face embedding would scan every face in view, bystanders included.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, face: Synth.axis(4, model: faceModel))]
        let roster = [RosterEntry(playerID: Synth.a), RosterEntry(playerID: Synth.b, consent: .init(clothes: false, face: true))]
        let snap = IdentitySnapshot(roster: IdentityRoster(entries: roster), appearanceGallery: [:],
                                    faceGallery: [Synth.b: [Synth.axis(4, model: faceModel)]])
        let analyzer = FakeAnalyzer(script: [1: people, 2: people])
        let out = await VisionShooterIdentifier(analyzer: analyzer)
            .identify(window(2), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(!analyzer.wants.isEmpty)
        #expect(analyzer.wants.allSatisfy { !$0.face && !$0.appearance })
        #expect(out.evidence.allSatisfy { $0.faceSimilarity.isEmpty })
        #expect(out.attribution.playerID == Synth.a && out.attribution.source == .turnOrder)
    }

    @Test func outOfTurnConsentedShooterSampleIsKeptWhenFallingBackToANonConsentedPlayer() async {
        // C (no consent) is expected; A (consented) actually shoots with a so-so match → turn order says C,
        // but the sample resembles A, so a later tap "A" can teach A's template.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.near(0, cos: 0.68, other: 9, model: bodyModel))]
        let snap = snapshot(clothes: [Synth.a: Synth.axis(0, model: bodyModel)],
                            roster: [RosterEntry(playerID: Synth.a, consent: .init(clothes: true, face: false)), RosterEntry(playerID: Synth.c)])
        let out = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]))
            .identify(window(1), snapshot: snap, expectedShooter: Synth.c, teamInTurn: nil)
        #expect(out.attribution.playerID == Synth.c && out.attribution.source == .turnOrder)
        #expect(out.shooterAppearance != nil)
    }

    @Test func nonConsentedShooterSampleIsDroppedEvenWhenAttributedToAConsentedPlayer() async {
        // A (consented) is expected; B (no consent) shoots and looks nothing like A → B's vector is never kept.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(5, model: bodyModel))]
        let snap = snapshot(clothes: [Synth.a: Synth.axis(0, model: bodyModel)],
                            roster: [RosterEntry(playerID: Synth.a, consent: .init(clothes: true, face: false)), RosterEntry(playerID: Synth.b)])
        let out = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]))
            .identify(window(1), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(out.attribution.playerID == Synth.a && out.attribution.source == .turnOrder)
        #expect(out.shooterAppearance == nil)
    }

    @Test func consentedPlayerWithEmptyGalleryIsBootstrappedOnTheirOwnTurn() async {
        // Guest G granted clothes consent, no template yet. On G's turn the shooter track's appearance is computed
        // and returned so the session can seed G (turn-order bind, research §7.2).
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(6, model: bodyModel))]
        let snap = snapshot(clothes: [:], roster: [RosterEntry(playerID: Synth.d, consent: .init(clothes: true, face: false), isGuest: true),
                                                   RosterEntry(playerID: Synth.b)])
        let analyzer = FakeAnalyzer(script: [1: people, 2: people])
        let out = await VisionShooterIdentifier(analyzer: analyzer)
            .identify(window(2), snapshot: snap, expectedShooter: Synth.d, teamInTurn: nil)
        #expect(analyzer.wants.allSatisfy { $0.appearance && !$0.face })
        #expect(out.attribution.playerID == Synth.d)
        #expect(out.shooterAppearance == Synth.axis(6, model: bodyModel))
    }

    @Test func emptyGalleryConsentedPlayerOffTurnRequestsNoEmbeddings() async {
        // Nothing to match against and nobody to bootstrap → don't compute anyone's appearance.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(6, model: bodyModel))]
        let snap = snapshot(clothes: [:], roster: [RosterEntry(playerID: Synth.d, consent: .init(clothes: true, face: false), isGuest: true),
                                                   RosterEntry(playerID: Synth.b)])
        let analyzer = FakeAnalyzer(script: [1: people])
        let out = await VisionShooterIdentifier(analyzer: analyzer)
            .identify(window(1), snapshot: snap, expectedShooter: Synth.b, teamInTurn: nil)
        #expect(analyzer.wants.allSatisfy { !$0.appearance && !$0.face })
        #expect(out.shooterAppearance == nil)
    }

    @MainActor @Test func sessionDrivesIdentifierAndRecordsResult() async {
        let p = PlayerProfile(id: Synth.a, name: "A", avatarSymbol: "star", avatarColor: "red")
        p.recognition = RecognitionData(faceEmbedding: nil,
                                        appearanceEmbedding: try! EmbeddingCodec.encode([Synth.axis(1, model: bodyModel)]),
                                        optedInAt: Date(timeIntervalSince1970: 1_700_000_000), version: 1)
        // B consented too: with a non-consenting B, A could never be picked over B (B might wear A's shirt, S1).
        let q = PlayerProfile(id: Synth.b, name: "B", avatarSymbol: "star", avatarColor: "blue")
        q.recognition = RecognitionData(faceEmbedding: nil,
                                        appearanceEmbedding: try! EmbeddingCodec.encode([Synth.axis(2, model: bodyModel)]),
                                        optedInAt: Date(timeIntervalSince1970: 1_700_000_000), version: 1)
        let session = await IdentitySession(profiles: [p, q], faceModelID: faceModel, bodyModelID: bodyModel)
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.near(1, cos: 0.97, other: 8, model: bodyModel))]
        let shot = UUID()
        let att = await session.identifyShot(shot, window: window(2), expectedShooter: Synth.b, teamInTurn: nil,
                                             using: VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people, 2: people])))
        #expect(att.playerID == Synth.a && att.source == .auto)
        #expect(await session.attribution(for: shot) == att)
        #expect(await session.pendingSampleCount == 1)
    }

    @MainActor @Test func guestBootstrapsThroughThePipeline() async {
        let session = IdentitySession(profiles: [], guests: [Synth.d, Synth.b], faceModelID: faceModel, bodyModelID: bodyModel)
        session.grantGuestClothesConsent(Synth.d)
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(6, model: bodyModel))]
        let att = await session.identifyShot(UUID(), window: window(2), expectedShooter: Synth.d, teamInTurn: nil,
                                             using: VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people, 2: people])))
        #expect(att.playerID == Synth.d)
        #expect(session.snapshot().appearanceGallery[Synth.d] == [Synth.axis(6, model: bodyModel)])
    }
}

@Suite struct ShooterGateAndFaceTests {
    let clothesAB = [RosterEntry(playerID: Synth.a, consent: .init(clothes: true, face: false)),
                     RosterEntry(playerID: Synth.b, consent: .init(clothes: true, face: false))]

    @Test func bystandersAreNeverComparedAndTheirVectorsNeverKept() async {
        // CX-1 / S7: only the gated shooter track is matched; a standing bystander's vector is ignored.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.axis(0, model: bodyModel)),
                      ObservedPerson(box: standerBox, joints: standingJoints, appearance: Synth.axis(1, model: bodyModel))]
        let snap = snapshot(clothes: [Synth.a: Synth.axis(0, model: bodyModel), Synth.b: Synth.axis(1, model: bodyModel)], roster: clothesAB)
        let analyzer = FakeAnalyzer(script: [1: people])
        let out = await VisionShooterIdentifier(analyzer: analyzer)
            .identify(window(1), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        let byPose = out.evidence.sorted { $0.poseScore > $1.poseScore }
        #expect(!byPose[0].appearanceSimilarity.isEmpty)
        #expect(byPose[1].appearanceSimilarity.isEmpty && byPose[1].faceSimilarity.isEmpty)
        #expect(analyzer.wants.allSatisfy { $0.cueBall == cue && $0.gate == .standard })
        #expect(out.attribution.playerID == Synth.a)
    }

    @Test func occludedShooterWithBystanderInViewIsTurnOrderAndKeepsNothing() async {
        // S7 / S8: nobody at the cue ball → no evidence, no sample, whoever stands in view.
        let people = [ObservedPerson(box: standerBox, joints: standingJoints, appearance: Synth.axis(1, model: bodyModel))]
        let snap = snapshot(clothes: [Synth.a: Synth.axis(0, model: bodyModel), Synth.b: Synth.axis(1, model: bodyModel)], roster: clothesAB)
        let out = await VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people, 2: people]))
            .identify(window(2), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(out.attribution.playerID == Synth.a && out.attribution.source == .turnOrder)
        #expect(out.attribution.shooterTrackID == nil && out.shooterAppearance == nil)
    }

    func faceSnapshot() -> IdentitySnapshot {
        IdentitySnapshot(roster: IdentityRoster(entries: [RosterEntry(playerID: Synth.a, consent: .init(clothes: false, face: true)),
                                                          RosterEntry(playerID: Synth.b, consent: .init(clothes: false, face: true))]),
                         appearanceGallery: [:],
                         faceGallery: [Synth.a: [Synth.axis(2, model: faceModel)], Synth.b: [Synth.axis(3, model: faceModel)]])
    }

    @Test func shooterOnlyFaceMatchingIdentifiesAVisibleGoodFace() async {
        // S5: with face matching on, the gated shooter's face is compared against face templates.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, face: Synth.near(3, cos: 0.95, other: 9, model: faceModel), faceQuality: 0.8),
                      ObservedPerson(box: standerBox, joints: standingJoints, face: Synth.axis(2, model: faceModel), faceQuality: 0.9)]
        let analyzer = FakeAnalyzer(script: [1: people, 2: people])
        let id = VisionShooterIdentifier(analyzer: analyzer, faceMatching: .shooterOnly)
        let out = await id.identify(window(2), snapshot: faceSnapshot(), expectedShooter: Synth.b, teamInTurn: nil)
        #expect(analyzer.wants.allSatisfy { $0.face && !$0.appearance })
        #expect(out.attribution.playerID == Synth.b && out.attribution.source == .auto)
        #expect(out.evidence.filter { !$0.faceSimilarity.isEmpty }.count == 1)    // the bystander's face never compared
    }

    @Test func poorQualityFacesNeverVote() async {
        // F4: a low faceCaptureQuality crop is not evidence (would otherwise push the posterior to A).
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, face: Synth.axis(2, model: faceModel), faceQuality: 0.2)]
        let id = VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]), faceMatching: .shooterOnly)
        let out = await id.identify(window(1), snapshot: faceSnapshot(), expectedShooter: Synth.b, teamInTurn: nil)
        #expect(out.evidence.allSatisfy { $0.faceSimilarity.isEmpty })
        #expect(out.attribution.playerID == Synth.b && out.attribution.source == .turnOrder)
    }

    @Test func calibrationIsChosenByTheTemplatesModelID() async {
        // F4 / CX-7: a model with its own calibration entry is trusted as far as that entry says, and no further.
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, face: Synth.near(3, cos: 0.95, other: 9, model: faceModel), faceQuality: 0.9)]
        let snap = IdentitySnapshot(roster: IdentityRoster(entries: [RosterEntry(playerID: Synth.a),
                                                                     RosterEntry(playerID: Synth.b, consent: .init(clothes: false, face: true))]),
                                    appearanceGallery: [:], faceGallery: [Synth.b: [Synth.axis(3, model: faceModel)]])
        let generic = VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]), faceMatching: .shooterOnly)
        #expect(await generic.identify(window(1), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil).attribution.source == .turnOrder)
        var table = IdentityCalibrationTable.standard
        table.face[faceModel] = ShooterAttributionTests.identityFace
        let trained = VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people]), faceMatching: .shooterOnly, calibrations: table)
        let out = await trained.identify(window(1), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(out.attribution.playerID == Synth.b && out.attribution.source == .auto)
    }
}

@Suite struct IdentityPrivacyLintTests {
    static let identityDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("CueCoach/Identity")

    func sources() throws -> [(String, String)] {
        let files = try FileManager.default.contentsOfDirectory(at: Self.identityDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func identityModuleMakesNoNetworkCalls() throws {
        let src = try sources()
        #expect(src.count >= 4)
        let banned = ["URLSession", "import Network", "NWConnection", "NWBrowser", "URLRequest", "http://", "https://",
                      "MultipeerConnectivity", "CloudKit"]
        for (name, text) in src { for b in banned { #expect(!text.contains(b), "\(name) contains \(b)") } }
    }

    @Test func sessionStateNeverTouchesDisk() throws {
        let session = try #require(try sources().first { $0.0 == "IdentitySession.swift" }).1
        for b in ["FileManager", "UserDefaults", ".write(", "save()", "insert("] {
            #expect(!session.contains(b), "IdentitySession.swift contains \(b)")
        }
    }
}
