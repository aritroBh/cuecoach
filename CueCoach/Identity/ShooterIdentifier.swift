import Foundation
import CoreGraphics

// ShooterIdentifier (docs/INTERFACES.md app-side protocol): frames around the stroke → who shot.

struct IdentityFrame: @unchecked Sendable {
    var image: CGImage
    /// Cue ball in Vision normalised image coordinates (origin lower-left), from Tracking.
    var cueBall: CGPoint
}

/// ±0.5 s around stroke start (research §5.2: event-driven, never per frame).
struct StrokeWindow: Sendable {
    var frames: [IdentityFrame]
}

protocol ShooterIdentifier: Sendable {
    func identify(_ window: StrokeWindow, snapshot: IdentitySnapshot, expectedShooter: UUID,
                  teamInTurn: Set<UUID>?) async -> ShooterIdentification
}

/// What Vision is allowed to compute. Embeddings are requested only when some roster player consented.
struct AnalysisWants: Hashable, Sendable {
    var appearance: Bool
    var face: Bool
}

struct ObservedPerson: Sendable {
    var box: CGRect
    var joints: BodyJoints
    var appearance: Embedding? = nil
    var face: Embedding? = nil
}

protocol PersonAnalyzing: Sendable {
    func people(in image: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson]
}

struct VisionShooterIdentifier: ShooterIdentifier {
    var analyzer: any PersonAnalyzing
    var attributor = ShooterAttributor()

    func identify(_ window: StrokeWindow, snapshot: IdentitySnapshot, expectedShooter: UUID,
                  teamInTurn: Set<UUID>?) async -> ShooterIdentification {
        let roster = snapshot.roster
        // Only consented players' templates are ever compared against.
        let clothesGallery = snapshot.appearanceGallery.filter { roster.clothesConsented.contains($0.key) && !$0.value.isEmpty }
        let faceGallery = snapshot.faceGallery.filter { roster.faceConsented.contains($0.key) && !$0.value.isEmpty }
        let wants = AnalysisWants(appearance: !clothesGallery.isEmpty, face: !faceGallery.isEmpty)
        let scorer = IdentityMatcher(threshold: 1, margin: 0)   // scores only; decisions happen in the attributor

        var assoc = TrackAssociator()
        var smoother = TrackEvidenceSmoother()
        var lastAppearance: [Int: Embedding] = [:]
        for frame in window.frames {
            guard let people = try? await analyzer.people(in: frame.image, wants: wants) else { continue }
            let ids = assoc.assign(people.map(\.box))
            for (person, track) in zip(people, ids) {
                var e = TrackEvidence(trackID: track, poseScore: ShootingPose.score(person.joints, cueBall: frame.cueBall),
                                      distanceToCueBall: Self.distance(person, frame.cueBall))
                if wants.appearance, let a = person.appearance {
                    e.appearanceSimilarity = scorer.match(a, against: clothesGallery).similarities
                    lastAppearance[track] = a
                }
                if wants.face, let f = person.face {
                    e.faceSimilarity = scorer.match(f, against: faceGallery).similarities
                }
                smoother.add(e)
            }
        }
        let evidence = smoother.evidence()
        let ctx = AttributionContext(roster: roster, expectedShooter: expectedShooter, teamInTurn: teamInTurn)
        let att = attributor.attribute(views: evidence.isEmpty ? [] : [evidence], context: ctx)
        let sample = roster.consent(of: att.playerID).clothes ? att.shooterTrackID.flatMap { lastAppearance[$0] } : nil
        return ShooterIdentification(attribution: att, shooterAppearance: sample, evidence: evidence)
    }

    static func distance(_ p: ObservedPerson, _ cue: CGPoint) -> Double {
        let wrists = [p.joints.points[.leftWrist], p.joints.points[.rightWrist]].compactMap { $0 }
        if let d = wrists.map({ ShootingPose.distance($0, cue) }).min() { return d }
        return ShootingPose.distance(CGPoint(x: p.box.midX, y: p.box.midY), cue)
    }
}
