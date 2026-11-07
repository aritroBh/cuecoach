import Foundation
import CoreGraphics

// Shooter attribution (SPEC §5.8, research §7.3). Pure logic; no Vision, no I/O.

/// Per-player recognition opt-ins. Both off by default (research §7.1, two consents).
struct RecognitionConsent: Hashable, Codable, Sendable {
    var clothes: Bool
    var face: Bool
    static let none = RecognitionConsent(clothes: false, face: false)

    init(clothes: Bool, face: Bool) { self.clothes = clothes; self.face = face }

    /// Consent is the presence of the stored template written at registration; deleting the row revokes both.
    init(faceData: Data?, appearanceData: Data?) {
        self.init(clothes: appearanceData != nil, face: faceData != nil)
    }
}

struct RosterEntry: Hashable, Sendable {
    var playerID: UUID
    var consent: RecognitionConsent = .none
    /// Guests have a colour avatar and no profile; never persisted by Identity.
    var isGuest = false
}

/// Everyone who may shoot in this session.
struct IdentityRoster: Hashable, Sendable {
    var entries: [RosterEntry]

    var ids: [UUID] { entries.map(\.playerID) }
    var clothesConsented: Set<UUID> { Set(entries.filter(\.consent.clothes).map(\.playerID)) }
    var faceConsented: Set<UUID> { Set(entries.filter(\.consent.face).map(\.playerID)) }
    var anyConsent: Bool { entries.contains { $0.consent.clothes || $0.consent.face } }
    func contains(_ id: UUID) -> Bool { entries.contains { $0.playerID == id } }
    func consent(of id: UUID) -> RecognitionConsent { entries.first { $0.playerID == id }?.consent ?? .none }
}

/// Named 2D joints in Vision's normalised image space (origin lower-left).
struct BodyJoints: Hashable, Sendable {
    enum Name: String, Hashable, Sendable, CaseIterable {
        case neck, root, leftWrist, rightWrist, leftElbow, rightElbow, leftShoulder, rightShoulder
    }
    var points: [Name: CGPoint]
}

/// "Person in shooting pose nearest the cue ball": bent torso + a hand at the cue ball.
enum ShootingPose {
    /// Distance scale (normalised image units) for the bridge-hand term. Assumption; tune on replays.
    static let reach: Double = 0.08

    static func score(_ j: BodyJoints, cueBall: CGPoint) -> Double {
        var bend = 0.0
        if let neck = j.points[.neck], let root = j.points[.root] {
            let dx = Double(neck.x - root.x), dy = Double(neck.y - root.y)
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 0 { bend = 1 - abs(dy) / len }
        }
        let wristDist = [j.points[.leftWrist], j.points[.rightWrist]].compactMap { $0 }
            .map { distance($0, cueBall) }.min()
        let hand = wristDist.map { exp(-$0 / reach) } ?? 0
        return min(1, max(0, 0.5 * bend + 0.5 * hand))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// What one view saw of one person track around the stroke. Similarities exist only for consented players.
struct TrackEvidence: Hashable, Sendable {
    var trackID: Int
    var poseScore: Double
    /// Normalised image distance from the person's nearest wrist (or box) to the cue ball.
    var distanceToCueBall: Double
    var appearanceSimilarity: [UUID: Double] = [:]
    var faceSimilarity: [UUID: Double] = [:]
}

/// Greedy IoU association of person boxes across the frames of one stroke window.
struct TrackAssociator: Sendable {
    var minIoU: Double = 0.3
    private var last: [Int: CGRect] = [:]
    private var nextID = 1

    init(minIoU: Double = 0.3) { self.minIoU = minIoU }

    mutating func assign(_ boxes: [CGRect]) -> [Int] {
        var free = last
        var out = [Int](repeating: 0, count: boxes.count)
        // Best pairs first so two boxes never fight over a track in index order.
        var pairs: [(Int, Int, Double)] = []
        for (i, b) in boxes.enumerated() { for (t, r) in free { pairs.append((i, t, Self.iou(b, r))) } }
        pairs.sort { $0.2 != $1.2 ? $0.2 > $1.2 : ($0.0, $0.1) < ($1.0, $1.1) }
        var used = Set<Int>()
        for (i, t, v) in pairs where v >= minIoU && out[i] == 0 && !used.contains(t) {
            out[i] = t; used.insert(t); free[t] = nil
        }
        var next: [Int: CGRect] = [:]
        for (i, b) in boxes.enumerated() {
            if out[i] == 0 { out[i] = nextID; nextID += 1 }
            next[out[i]] = b
        }
        last = next
        return out
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
    }
}

/// Re-ID smoothing over a stroke window: mean similarity per player, best pose, nearest approach.
struct TrackEvidenceSmoother: Sendable {
    private struct Acc { var pose = 0.0; var dist = Double.infinity
                         var app: [UUID: (Double, Int)] = [:]; var face: [UUID: (Double, Int)] = [:] }
    private var tracks: [Int: Acc] = [:]

    mutating func add(_ e: TrackEvidence) {
        var a = tracks[e.trackID] ?? Acc()
        a.pose = max(a.pose, e.poseScore)
        a.dist = min(a.dist, e.distanceToCueBall)
        for (p, s) in e.appearanceSimilarity { let o = a.app[p] ?? (0, 0); a.app[p] = (o.0 + s, o.1 + 1) }
        for (p, s) in e.faceSimilarity { let o = a.face[p] ?? (0, 0); a.face[p] = (o.0 + s, o.1 + 1) }
        tracks[e.trackID] = a
    }

    func evidence() -> [TrackEvidence] {
        tracks.keys.sorted().map { id in
            let a = tracks[id]!
            return TrackEvidence(trackID: id, poseScore: a.pose, distanceToCueBall: a.dist,
                                 appearanceSimilarity: a.app.mapValues { $0.0 / Double($0.1) },
                                 faceSimilarity: a.face.mapValues { $0.0 / Double($0.1) })
        }
    }
}

struct AttributionContext: Sendable {
    var roster: IdentityRoster
    /// Who should be shooting by turn order / rules (the fallback).
    var expectedShooter: UUID
    /// Members of the team in turn; nil = everyone (1v1 or unknown).
    var teamInTurn: Set<UUID>? = nil
}

struct Attribution: Hashable, Sendable {
    var playerID: UUID
    var source: AttributionSource
    var confidence: Double
    var shooterTrackID: Int?
}

/// P(p shot) ∝ Prior(p) × Π_views Σ_tracks w(track)·LR_p(track)   (research §7.3)
/// LR is the calibrated genuine/impostor likelihood ratio for consented players and exactly 1 (no evidence)
/// for everyone else, so a non-consented player's appearance is never an input.
struct ShooterAttributor: Sendable {
    struct Parameters: Hashable, Sendable {
        var expectedPrior = 0.80
        var offTeamPrior = 0.01
        var decideAt = 0.85
        var margin = 0.30
        var poseSharpness = 8.0
        var distancePenalty = 2.0
        var clothes = SimilarityCalibration(threshold: 0.75, slope: 25)
        var face = SimilarityCalibration(threshold: 0.75, slope: 25)
        var lrRange: ClosedRange<Double> = 0.01...100
    }
    var parameters = Parameters()

    func prior(_ ctx: AttributionContext) -> [UUID: Double] {
        let ids = ctx.roster.ids
        guard !ids.isEmpty else { return [:] }
        let team = ctx.teamInTurn ?? Set(ids)
        let others = ids.filter { $0 != ctx.expectedShooter }
        let onTeam = others.filter { team.contains($0) }
        let offTeam = others.filter { !team.contains($0) }
        let hasExpected = ids.contains(ctx.expectedShooter)
        var p: [UUID: Double] = [:]
        let offMass = parameters.offTeamPrior * Double(offTeam.count)
        let expectedMass = hasExpected ? (others.isEmpty ? 1 : parameters.expectedPrior) : 0
        let rest = max(0, 1 - expectedMass - offMass)
        if hasExpected { p[ctx.expectedShooter] = expectedMass }
        for id in onTeam { p[id] = rest / Double(onTeam.count) }
        for id in offTeam { p[id] = onTeam.isEmpty ? (1 - expectedMass) / Double(offTeam.count) : parameters.offTeamPrior }
        let z = p.values.reduce(0, +)
        return z > 0 ? p.mapValues { $0 / z } : Dictionary(uniqueKeysWithValues: ids.map { ($0, 1 / Double(ids.count)) })
    }

    private func weights(_ tracks: [TrackEvidence]) -> [Double] {
        let raw = tracks.map { parameters.poseSharpness * ($0.poseScore - parameters.distancePenalty * $0.distanceToCueBall) }
        let m = raw.max() ?? 0
        let e = raw.map { exp($0 - m) }
        let z = e.reduce(0, +)
        return e.map { $0 / z }
    }

    private func likelihoodRatio(_ p: UUID, _ t: TrackEvidence, _ consent: RecognitionConsent) -> Double {
        var logLR = 0.0
        if consent.clothes, let s = t.appearanceSimilarity[p] { logLR += logit(parameters.clothes.probability(s)) }
        if consent.face, let s = t.faceSimilarity[p] { logLR += logit(parameters.face.probability(s)) }
        return min(parameters.lrRange.upperBound, max(parameters.lrRange.lowerBound, exp(logLR)))
    }

    private func logit(_ q: Double) -> Double {
        let c = min(1 - 1e-12, max(1e-12, q))
        return log(c / (1 - c))
    }

    func posterior(views: [[TrackEvidence]], context ctx: AttributionContext) -> [UUID: Double] {
        var logp = prior(ctx).mapValues { log(max($0, 1e-300)) }
        for view in views where !view.isEmpty {
            let w = weights(view)
            for p in Array(logp.keys) {
                let consent = ctx.roster.consent(of: p)
                let l = zip(view, w).reduce(0.0) { $0 + $1.1 * likelihoodRatio(p, $1.0, consent) }
                logp[p]! += log(max(l, 1e-300))
            }
        }
        guard let m = logp.values.max() else { return [:] }
        let e = logp.mapValues { exp($0 - m) }
        let z = e.values.reduce(0, +)
        return e.mapValues { $0 / z }
    }

    func attribute(views: [[TrackEvidence]], context ctx: AttributionContext) -> Attribution {
        let post = posterior(views: views, context: ctx)
        let ranked = post.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
        let track = shooterTrack(views)
        if let top = ranked.first, top.value >= parameters.decideAt,
           top.value - (ranked.dropFirst().first?.value ?? 0) >= parameters.margin {
            return Attribution(playerID: top.key, source: .auto, confidence: top.value, shooterTrackID: track)
        }
        return Attribution(playerID: ctx.expectedShooter, source: .turnOrder,
                           confidence: post[ctx.expectedShooter] ?? 0, shooterTrackID: track)
    }

    /// The most shooter-like track across all views (for template updates on correction).
    private func shooterTrack(_ views: [[TrackEvidence]]) -> Int? {
        views.flatMap { $0 }.max {
            ($0.poseScore - parameters.distancePenalty * $0.distanceToCueBall)
                < ($1.poseScore - parameters.distancePenalty * $1.distanceToCueBall)
        }?.trackID
    }
}
