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

/// What Vision is allowed to compute. Embeddings are requested only when some roster player consented and they can be used.
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

    /// Stroke-time face embedding is off: it would embed every face in view, bystanders included. That is only
    /// allowed in a ≤ 10 s check-in window started by an opted-in player, and only if Q10 = allow (open; default
    /// no). Face templates are held but never compared here (research §7.2, §7.4).
    static let strokeTimeFaceMatching = false

    func identify(_ window: StrokeWindow, snapshot: IdentitySnapshot, expectedShooter: UUID,
                  teamInTurn: Set<UUID>?) async -> ShooterIdentification {
        let roster = snapshot.roster
        // Only consented players' templates are ever compared against.
        let clothesGallery = snapshot.appearanceGallery.filter { roster.clothesConsented.contains($0.key) && !$0.value.isEmpty }
        let faceGallery = snapshot.faceGallery.filter { roster.faceConsented.contains($0.key) && !$0.value.isEmpty }
        // Appearance is computed to match a template, or to seed a consented player with none on their own turn.
        let bootstrap = roster.consent(of: expectedShooter).clothes && clothesGallery[expectedShooter] == nil
        let wants = AnalysisWants(appearance: !clothesGallery.isEmpty || bootstrap,
                                  face: Self.strokeTimeFaceMatching && !faceGallery.isEmpty)
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
                    if !clothesGallery.isEmpty { e.appearanceSimilarity = scorer.match(a, against: clothesGallery).similarities }
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
        // Keep the shooter track's vector only if it could teach some consented player (whoever was attributed);
        // a non-consented shooter's or bystander's vector is dropped here.
        let sample = att.shooterTrackID.flatMap { lastAppearance[$0] }.flatMap {
            AppearanceLearning.mayHold($0, roster: roster, gallery: clothesGallery, expectedShooter: expectedShooter) ? $0 : nil
        }
        return ShooterIdentification(attribution: att, shooterAppearance: sample, evidence: evidence)
    }

    static func distance(_ p: ObservedPerson, _ cue: CGPoint) -> Double {
        let wrists = [p.joints.points[.leftWrist], p.joints.points[.rightWrist]].compactMap { $0 }
        if let d = wrists.map({ ShootingPose.distance($0, cue) }).min() { return d }
        return ShootingPose.distance(CGPoint(x: p.box.midX, y: p.box.midY), cue)
    }
}
