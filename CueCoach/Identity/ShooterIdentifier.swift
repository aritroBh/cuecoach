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

/// What Vision is allowed to compute. Embeddings are requested only when some plausible shooter consented, and only
/// for people the `gate` admits as the shooter at `cueBall`: standing bystanders are never embedded.
struct AnalysisWants: Hashable, Sendable {
    var appearance: Bool
    var face: Bool
    var cueBall = CGPoint(x: 0.5, y: 0.5)
    var gate = ShooterGate.standard

    /// May this person's appearance / face be embedded at all?
    func admits(_ joints: BodyJoints, box: CGRect) -> Bool {
        gate.admits(pose: ShootingPose.score(joints, cueBall: cueBall),
                    distance: ShootingPose.reachDistance(joints, box: box, cueBall: cueBall))
    }
}

struct ObservedPerson: Sendable {
    var box: CGRect
    var joints: BodyJoints
    var appearance: Embedding? = nil
    var face: Embedding? = nil
    /// `DetectFaceCaptureQualityRequest` score of the face crop behind `face`, in [0, 1].
    var faceQuality: Double? = nil
}

protocol PersonAnalyzing: Sendable {
    func people(in image: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson]
}

/// Stroke-time face matching. Off by default: research Q10 (transient embedding of a non-consenting shooter's face)
/// is a user + legal decision. `.shooterOnly` embeds only the gated shooter's face, behind the quality gate;
/// bystanders' faces are never embedded either way.
enum StrokeFaceMatching: Hashable, Sendable { case off, shooterOnly }

struct VisionShooterIdentifier: ShooterIdentifier {
    var analyzer: any PersonAnalyzing
    var attributor = ShooterAttributor()
    var faceMatching = StrokeFaceMatching.off
    var calibrations = IdentityCalibrationTable.standard
    /// F6: the on-device benchmark result. `.shooterOnly` is honoured only when it passed for the gallery's face model.
    var faceGate: FaceShipGateRecord? = FaceShipGateStore().load()
    /// Faces below this capture quality never vote (research §7.1 assumption, face-embedding.md F4).
    var minFaceQuality = 0.5

    func identify(_ window: StrokeWindow, snapshot: IdentitySnapshot, expectedShooter: UUID,
                  teamInTurn: Set<UUID>?) async -> ShooterIdentification {
        let roster = snapshot.roster
        let ctx = AttributionContext(roster: roster, expectedShooter: expectedShooter, teamInTurn: teamInTurn)
        // Only consented players' templates are ever compared against.
        let clothesGallery = snapshot.appearanceGallery.filter { roster.clothesConsented.contains($0.key) && !$0.value.isEmpty }
        let faceGallery = snapshot.faceGallery.filter { roster.faceConsented.contains($0.key) && !$0.value.isEmpty }
        var attributor = attributor
        attributor.parameters.clothes = calibrations.clothes(clothesGallery.values.first?.first?.modelID)
        let faceModelID = faceGallery.values.first?.first?.modelID
        let gateOpen = faceModelID != nil && faceGate?.modelID == faceModelID && (faceGate?.meetsD28 ?? false)
        var calibrations = calibrations
        if gateOpen, let id = faceModelID, calibrations.face[id] == nil, let g = faceGate { calibrations.face[id] = g.cueModel }
        attributor.parameters.face = calibrations.face(faceModelID)
        let gate = attributor.parameters.gate
        // r2 BLOCKER 1: appearance is computed only to compare against an existing consented template. There is no
        // bootstrap from a turn-order guess: an empty gallery means nobody at the cue ball is embedded at all.
        let wantsAppearance = !clothesGallery.isEmpty
        let wantsFace = faceMatching == .shooterOnly && gateOpen
        let scorer = IdentityMatcher(threshold: 1, margin: 0)   // scores only; decisions happen in the attributor

        var assoc = TrackAssociator()
        var smoother = TrackEvidenceSmoother()
        var lastAppearance: [Int: Embedding] = [:]
        for frame in window.frames {
            // Revoke / session end cancels the task: stop before computing anything more (r2 MAJOR).
            if Task.isCancelled { return Self.cancelled(expectedShooter) }
            let wants = AnalysisWants(appearance: wantsAppearance, face: wantsFace, cueBall: frame.cueBall, gate: gate)
            guard let people = try? await analyzer.people(in: frame.image, wants: wants) else { continue }
            if Task.isCancelled { return Self.cancelled(expectedShooter) }
            let ids = assoc.assign(people.map(\.box))
            for (person, track) in zip(people, ids) {
                var e = TrackEvidence(trackID: track, poseScore: ShootingPose.score(person.joints, cueBall: frame.cueBall),
                                      distanceToCueBall: ShootingPose.reachDistance(person.joints, box: person.box,
                                                                                    cueBall: frame.cueBall))
                // A non-shooter's vectors are never compared or kept, whatever the analyzer returned.
                if gate.admits(e) {
                    if wants.appearance, let a = person.appearance {
                        e.appearanceSimilarity = Self.belowCeiling(scorer.match(a, against: clothesGallery).similarities,
                                                                   snapshot.appearanceClaimCeiling)
                        lastAppearance[track] = a
                    }
                    if wants.face, let f = person.face, (person.faceQuality ?? 0) >= minFaceQuality {
                        e.faceSimilarity = Self.belowCeiling(scorer.match(f, against: faceGallery).similarities,
                                                             snapshot.faceClaimCeiling)
                    }
                }
                smoother.add(e)
            }
        }
        let evidence = smoother.evidence()
        let att = attributor.attribute(views: evidence.isEmpty ? [] : [evidence], context: ctx)
        // Keep the gated shooter track's vector only if a tap could teach some consented player with it (see
        // `AppearanceLearning.mayHold`); it is never learned without a tap. Anything else is dropped here.
        let sample = att.shooterTrackID.flatMap { lastAppearance[$0] }.flatMap {
            AppearanceLearning.mayHold($0, roster: roster, gallery: clothesGallery, expectedShooter: expectedShooter) ? $0 : nil
        }
        return ShooterIdentification(attribution: att, shooterAppearance: sample, evidence: evidence)
    }

    static func cancelled(_ expected: UUID) -> ShooterIdentification {
        ShooterIdentification(attribution: .unknown(suggested: expected, confidence: 0, shooterTrackID: nil), shooterAppearance: nil)
    }

    /// S9 negative signal: a template corrected away from a look may not claim a look that is no more like it than
    /// the corrected one was (+ `claimMargin`). Its similarity is dropped, so that player is unmodelled on this track.
    static let claimMargin = 0.02
    static func belowCeiling(_ sims: [UUID: Double], _ ceiling: [UUID: Double]) -> [UUID: Double] {
        sims.filter { p, s in ceiling[p].map { s > $0 + claimMargin } ?? true }
    }
}
