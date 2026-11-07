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
            ObservedPerson(box: $0.box, joints: $0.joints,
                           appearance: wants.appearance ? $0.appearance : nil, face: wants.face ? $0.face : nil)
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

    @Test func faceMatchUsedOnlyWithFaceConsent() async {
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, face: Synth.axis(4, model: faceModel))]
        let roster = [RosterEntry(playerID: Synth.a), RosterEntry(playerID: Synth.b, consent: .init(clothes: false, face: true))]
        let snap = IdentitySnapshot(roster: IdentityRoster(entries: roster), appearanceGallery: [:],
                                    faceGallery: [Synth.b: [Synth.axis(4, model: faceModel)]])
        let analyzer = FakeAnalyzer(script: [1: people, 2: people])
        let out = await VisionShooterIdentifier(analyzer: analyzer)
            .identify(window(2), snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(analyzer.wants.allSatisfy { $0.face && !$0.appearance })
        #expect(out.attribution.playerID == Synth.b)
    }

    @MainActor @Test func sessionDrivesIdentifierAndRecordsResult() async {
        let p = PlayerProfile(id: Synth.a, name: "A", avatarSymbol: "star", avatarColor: "red")
        p.recognition = RecognitionData(faceEmbedding: nil,
                                        appearanceEmbedding: try! EmbeddingCodec.encode([Synth.axis(1, model: bodyModel)]),
                                        optedInAt: Date(timeIntervalSince1970: 1_700_000_000), version: 1)
        let q = PlayerProfile(id: Synth.b, name: "B", avatarSymbol: "star", avatarColor: "blue")
        let session = await IdentitySession(profiles: [p, q], faceModelID: faceModel, bodyModelID: bodyModel)
        let people = [ObservedPerson(box: shooterBox, joints: shooterJoints, appearance: Synth.near(1, cos: 0.97, other: 8, model: bodyModel))]
        let shot = UUID()
        let att = await session.identifyShot(shot, window: window(2), expectedShooter: Synth.b, teamInTurn: nil,
                                             using: VisionShooterIdentifier(analyzer: FakeAnalyzer(script: [1: people, 2: people])))
        #expect(att.playerID == Synth.a && att.source == .auto)
        #expect(await session.attribution(for: shot) == att)
        #expect(await session.pendingSampleCount == 1)
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
