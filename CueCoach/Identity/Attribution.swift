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

    /// Nearest wrist to the cue ball, or the box centre when no wrist was found.
    static func reachDistance(_ j: BodyJoints, box: CGRect, cueBall: CGPoint) -> Double {
        let wrists = [j.points[.leftWrist], j.points[.rightWrist]].compactMap { $0 }
        if let d = wrists.map({ distance($0, cueBall) }).min() { return d }
        return distance(CGPoint(x: box.midX, y: box.midY), cueBall)
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
/// A track survives `maxMissed` frames unseen (cue-arm occlusion, a pose miss) before it is retired.
struct TrackAssociator: Sendable {
    static let defaultMaxMissed = 2
    var minIoU: Double
    var maxMissed: Int
    private var live: [Int: (box: CGRect, missed: Int)] = [:]
    private var nextID = 1

    init(minIoU: Double = 0.3, maxMissed: Int = TrackAssociator.defaultMaxMissed) {
        self.minIoU = minIoU; self.maxMissed = maxMissed
    }

    mutating func assign(_ boxes: [CGRect]) -> [Int] {
        var out = [Int](repeating: 0, count: boxes.count)
        // Best pairs first so two boxes never fight over a track in index order; fresher tracks win ties.
        var pairs: [(Int, Int, Double, Int)] = []
        for (i, b) in boxes.enumerated() { for (t, r) in live { pairs.append((i, t, Self.iou(b, r.box), r.missed)) } }
        pairs.sort { $0.2 != $1.2 ? $0.2 > $1.2 : ($0.3, $0.0, $0.1) < ($1.3, $1.0, $1.1) }
        var used = Set<Int>()
        for (i, t, v, _) in pairs where v >= minIoU && out[i] == 0 && !used.contains(t) {
            out[i] = t; used.insert(t)
        }
        var next: [Int: (box: CGRect, missed: Int)] = [:]
        for (t, r) in live where !used.contains(t) && r.missed < maxMissed { next[t] = (r.box, r.missed + 1) }
        for (i, b) in boxes.enumerated() {
            if out[i] == 0 { out[i] = nextID; nextID += 1 }
            next[out[i]] = (b, 0)
        }
        live = next
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

    /// Who could plausibly be shooting: the team in turn, or everyone. A team that does not contain the expected
    /// shooter is stale game state (foul, re-rack, roster change), so it is ignored rather than trusted.
    var plausibleShooters: Set<UUID> {
        let all = Set(roster.ids)
        guard let t = teamInTurn, t.contains(expectedShooter) else { return all }
        return t.intersection(all)
    }
}

/// How a shot's shooter was decided. `.unknown` credits nobody: the post-shot card asks with one tap.
enum AttributionDecision: String, Hashable, Sendable { case auto, turnOrder, tap, unknown }

struct Attribution: Hashable, Sendable {
    /// Credited shooter; nil only for `.unknown` (nobody gets the shot until a tap names them).
    var playerID: UUID?
    var source: AttributionDecision
    var confidence: Double
    var shooterTrackID: Int?
    /// The turn-order pick the card offers first when asking. Never credited without a tap.
    var suggestedPlayerID: UUID? = nil

    init(playerID: UUID, source: AttributionDecision, confidence: Double, shooterTrackID: Int?) {
        self.playerID = playerID; self.source = source; self.confidence = confidence; self.shooterTrackID = shooterTrackID
    }

    /// Unknown or tied evidence: ask, never a silent turn-order ID.
    static func unknown(suggested: UUID?, confidence: Double, shooterTrackID: Int?) -> Attribution {
        var a = Attribution(playerID: UUID(), source: .unknown, confidence: confidence, shooterTrackID: shooterTrackID)
        a.playerID = nil
        a.suggestedPlayerID = suggested
        return a
    }

    var needsConfirmation: Bool { source == .unknown }

    /// What `Shot.attributionSource` stores; nil = do not credit the shot to anyone yet.
    var storedSource: AttributionSource? {
        switch source {
        case .auto: .auto
        case .turnOrder: .turnOrder
        case .tap: .tap
        case .unknown: nil
        }
    }
}

/// "Somebody is actually shooting here": an absolute gate on top of the relative track weights.
/// A track that fails it is never evidence and never yields a learning sample (a standing bystander is not the
/// shooter just because the real shooter is occluded).
struct ShooterGate: Hashable, Sendable {
    var minPose = 0.5
    /// Normalised image distance from the nearest wrist (or box centre) to the cue ball.
    var maxDistance = 0.15
    static let standard = ShooterGate()

    func admits(pose: Double, distance: Double) -> Bool { pose >= minPose && distance <= maxDistance }
    func admits(_ t: TrackEvidence) -> Bool { admits(pose: t.poseScore, distance: t.distanceToCueBall) }
}

/// One recognition cue (clothes or face) for one embedding model: how a cosine maps to a likelihood ratio,
/// and how likely it is that some *unmodelled* person (no consent, guest, stranger) scores like a template.
/// `lookalikeRate` = 1 means "anyone could look like this" (clothes: team shirts; a generic image embedding
/// on faces); an identity-trained face model earns a small value from the consented benchmark only.
struct CueModel: Hashable, Sendable {
    var calibration: SimilarityCalibration
    var lookalikeRate: Double
    var lrRange: ClosedRange<Double>

    func likelihoodRatio(_ cosine: Double) -> Double {
        let q = min(1 - 1e-12, max(1e-12, calibration.probability(cosine)))
        return min(lrRange.upperBound, max(lrRange.lowerBound, q / (1 - q)))
    }

    /// LR for a candidate who has no template for this cue, given the best modelled LR on the same track:
    /// with probability `lookalikeRate` they look like the best match, otherwise like a random impostor (LR 1).
    func unmodelledLikelihoodRatio(bestModelled: Double) -> Double {
        max(1, lookalikeRate * bestModelled + (1 - lookalikeRate))
    }

    /// Clothing feature print. Calibration values are assumptions until the replay study (research §9.3).
    static let clothes = CueModel(calibration: .init(threshold: 0.75, slope: 25), lookalikeRate: 1, lrRange: 0.01...100)
    /// Generic image feature print on a face crop: not identity-trained, so it may confirm but never decide alone.
    static let genericFace = CueModel(calibration: .init(threshold: 0.80, slope: 15), lookalikeRate: 1, lrRange: 0.5...3)
}

/// Per-model calibration. A model is only trusted as far as its entry says; unknown models get the conservative
/// defaults. A licence-clean identity-trained face model adds its own entry after the §6 benchmark (face-embedding.md).
struct IdentityCalibrationTable: Sendable {
    var clothes: [String: CueModel] = [:]
    var face: [String: CueModel] = [:]
    var defaultClothes = CueModel.clothes
    var defaultFace = CueModel.genericFace
    static let standard = IdentityCalibrationTable()

    func clothes(_ modelID: String?) -> CueModel { modelID.flatMap { clothes[$0] } ?? defaultClothes }
    func face(_ modelID: String?) -> CueModel { modelID.flatMap { face[$0] } ?? defaultFace }
}

/// P(p shot) ∝ Prior(p) × Π_views Σ_gated tracks w(track)·LR_p(track)   (research §7.3)
///
/// Open set: a candidate with no template for a cue (no consent, guest, failed enrolment) is not "LR 1": they might
/// wear the same shirt. Their LR for that cue is `CueModel.unmodelledLikelihoodRatio` of the best modelled match,
/// so a consented player can never out-score an unmodelled one on clothes alone (S1/S6/S9). Only tracks that pass
/// the `ShooterGate` count; with none, the answer is turn order (S8).
///
/// `.auto` also needs *positive* evidence for the winner (Π L_view > 1): a pick nobody's evidence supports is turn order.
struct ShooterAttributor: Sendable {
    struct Parameters: Hashable, Sendable {
        var expectedPrior = 0.80
        var offTeamPrior = 0.01
        var decideAt = 0.85
        var margin = 0.30
        var poseSharpness = 8.0
        var distancePenalty = 2.0
        var clothes = CueModel.clothes
        var face = CueModel.genericFace
        var gate = ShooterGate.standard
        var lrRange: ClosedRange<Double> = 0.01...100
        /// Below this posterior for the turn-order pick (and no safe auto pick) the card asks instead.
        var askBelow = 0.5
        /// `.auto` needs the pick's evidence to beat every other plausible shooter's (open-set) evidence by this
        /// factor, independent of the prior: the 0.8 turn prior alone may never turn a tie into a confident call
        /// (a lookalike guest shooting out of turn, lookalike teammates).
        var minEvidenceRatio = 4.0
        /// Someone outside the roster may shoot (open venue). Off: the roster is everyone who may shoot.
        var strangerPossible = false
    }
    var parameters = Parameters()

    func prior(_ ctx: AttributionContext) -> [UUID: Double] {
        let ids = ctx.roster.ids
        guard !ids.isEmpty else { return [:] }
        let team = ctx.plausibleShooters
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

    /// Tracks that could be the shooter.
    func gated(_ view: [TrackEvidence]) -> [TrackEvidence] { view.filter(parameters.gate.admits) }

    private func weights(_ tracks: [TrackEvidence]) -> [Double] {
        let raw = tracks.map { parameters.poseSharpness * ($0.poseScore - parameters.distancePenalty * $0.distanceToCueBall) }
        let m = raw.max() ?? 0
        let e = raw.map { exp($0 - m) }
        let z = e.reduce(0, +)
        return e.map { $0 / z }
    }

    /// LR of every roster player for one track. `openSet`: unmodelled candidates get the lookalike LR per cue (for the
    /// posterior); otherwise they get 1, so only a real template match counts as *positive* evidence for `.auto`.
    func likelihoodRatios(_ t: TrackEvidence, roster: IdentityRoster, openSet: Bool = true) -> [UUID: Double] {
        func cue(_ sims: (UUID) -> Double?, _ consented: (RecognitionConsent) -> Bool, _ model: CueModel) -> [UUID: Double]? {
            var modelled: [UUID: Double] = [:]
            for e in roster.entries where consented(e.consent) {
                if let s = sims(e.playerID) { modelled[e.playerID] = model.likelihoodRatio(s) }
            }
            guard let best = modelled.values.max() else { return nil }   // cue not observed on this track
            let other = openSet ? model.unmodelledLikelihoodRatio(bestModelled: best) : 1
            return Dictionary(uniqueKeysWithValues: roster.ids.map { ($0, modelled[$0] ?? other) })
        }
        let cues = [cue({ t.appearanceSimilarity[$0] }, \.clothes, parameters.clothes),
                    cue({ t.faceSimilarity[$0] }, \.face, parameters.face)].compactMap { $0 }
        var lr = Dictionary(uniqueKeysWithValues: roster.ids.map { ($0, 1.0) })
        for c in cues { for (p, v) in c { lr[p, default: 1] *= v } }
        return lr.mapValues { min(parameters.lrRange.upperBound, max(parameters.lrRange.lowerBound, $0)) }
    }

    /// log Π_views L_view(p) for every roster player, over gated tracks only.
    private func logEvidence(_ views: [[TrackEvidence]], roster: IdentityRoster, openSet: Bool = true) -> [UUID: Double] {
        var out = Dictionary(uniqueKeysWithValues: roster.ids.map { ($0, 0.0) })
        for view in views {
            let tracks = gated(view)
            guard !tracks.isEmpty else { continue }
            let w = weights(tracks)
            let lrs = tracks.map { likelihoodRatios($0, roster: roster, openSet: openSet) }
            for p in roster.ids {
                let l = zip(lrs, w).reduce(0.0) { $0 + $1.1 * ($1.0[p] ?? 1) }
                out[p]! += log(max(l, 1e-300))
            }
        }
        return out
    }

    func posterior(views: [[TrackEvidence]], context ctx: AttributionContext) -> [UUID: Double] {
        let ev = logEvidence(views, roster: ctx.roster)
        let logp = prior(ctx).mapValues { log(max($0, 1e-300)) }.merging(ev) { $0 + $1 }
        guard let m = logp.values.max() else { return [:] }
        let e = logp.mapValues { exp($0 - m) }
        let z = e.values.reduce(0, +)
        return e.mapValues { $0 / z }
    }

    /// Competitor set (r2 BLOCKER 2): *every* roster member, off-team players and guests included, plus an explicit
    /// "someone else" hypothesis (an unmodelled person: guest, no consent, stranger) whenever one could be shooting.
    ///
    /// - `.auto`: the winner's evidence beats every competitor's *and* "someone else"'s by `minEvidenceRatio`, with
    ///   positive evidence of its own, and the posterior clears `decideAt` / `margin`.
    /// - `.turnOrder` (silent): only when no guest could be at the cue ball unseen (or the expected shooter is the
    ///   guest), the expected shooter is in the roster, and observed evidence neither contradicts them nor ties them
    ///   with another *recognisable* player.
    /// - `.unknown` otherwise: the card asks, nobody is credited.
    func attribute(views: [[TrackEvidence]], context ctx: AttributionContext) -> Attribution {
        let post = posterior(views: views, context: ctx)
        let ranked = post.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
        let track = shooterTrack(views)
        let open = logEvidence(views, roster: ctx.roster)
        let closed = logEvidence(views, roster: ctx.roster, openSet: false)
        let guestPresent = ctx.roster.entries.contains(where: \.isGuest) || parameters.strangerPossible
        let someoneElse = guestPresent || ctx.roster.entries.contains { $0.consent == .none }
        let elseEvidence = someoneElse ? logSomeoneElseEvidence(views, roster: ctx.roster) : -Double.infinity
        let ratio = log(parameters.minEvidenceRatio)
        func separated(_ p: UUID) -> Bool {
            let mine = open[p] ?? 0
            return ctx.roster.ids.allSatisfy { $0 == p || mine - (open[$0] ?? 0) >= ratio } && mine - elseEvidence >= ratio
        }
        if let top = ranked.first, top.value >= parameters.decideAt,
           top.value - (ranked.dropFirst().first?.value ?? 0) >= parameters.margin,
           (closed[top.key] ?? 0) > 0, separated(top.key) {
            return Attribution(playerID: top.key, source: .auto, confidence: top.value, shooterTrackID: track)
        }
        let e = ctx.expectedShooter
        let p = post[e] ?? 0
        let ask = Attribution.unknown(suggested: e, confidence: p, shooterTrackID: track)
        guard let entry = ctx.roster.entries.first(where: { $0.playerID == e }) else { return ask }
        // A guest could be the one shooting (seen or not): a registered profile is never silently credited.
        if guestPresent && !entry.isGuest { return ask }
        guard track != nil else { return Attribution(playerID: e, source: .turnOrder, confidence: p, shooterTrackID: nil) }
        if p < parameters.askBelow { return ask }
        // Tie with a recognisable player: someone whose own template matches (positive evidence) is within the ratio.
        let mine = open[e] ?? 0
        let tied = ctx.roster.ids.contains { $0 != e && (closed[$0] ?? 0) > 0 && mine - (open[$0] ?? 0) < ratio }
        if tied { return ask }
        return Attribution(playerID: e, source: .turnOrder, confidence: p, shooterTrackID: track)
    }

    /// log Π_views L_view(someone else): an unmodelled person scores the open-set lookalike LR of each observed cue.
    private func logSomeoneElseEvidence(_ views: [[TrackEvidence]], roster: IdentityRoster) -> Double {
        var out = 0.0
        for view in views {
            let tracks = gated(view)
            guard !tracks.isEmpty else { continue }
            let w = weights(tracks)
            let l = zip(tracks, w).reduce(0.0) { acc, tw in
                let (t, wt) = tw
                var lr = 1.0
                let app = roster.entries.filter(\.consent.clothes).compactMap { t.appearanceSimilarity[$0.playerID] }
                    .map(parameters.clothes.likelihoodRatio).max()
                let face = roster.entries.filter(\.consent.face).compactMap { t.faceSimilarity[$0.playerID] }
                    .map(parameters.face.likelihoodRatio).max()
                if let a = app { lr *= parameters.clothes.unmodelledLikelihoodRatio(bestModelled: a) }
                if let f = face { lr *= parameters.face.unmodelledLikelihoodRatio(bestModelled: f) }
                return acc + wt * min(parameters.lrRange.upperBound, max(parameters.lrRange.lowerBound, lr))
            }
            out += log(max(l, 1e-300))
        }
        return out
    }

    /// Π_views L_view(p) from p's own templates: > 1 only when the gated views actually look like p.
    /// An unmodelled player never has positive evidence (they can't be ruled out, but they can't be recognised).
    func evidence(for p: UUID, views: [[TrackEvidence]], roster: IdentityRoster) -> Double {
        exp(logEvidence(views, roster: roster, openSet: false)[p] ?? 0)
    }

    /// The most shooter-like *gated* track across all views; nil when nobody is in shooting pose at the cue ball.
    func shooterTrack(_ views: [[TrackEvidence]]) -> Int? {
        views.flatMap(gated).max {
            ($0.poseScore - parameters.distancePenalty * $0.distanceToCueBall)
                < ($1.poseScore - parameters.distancePenalty * $1.distanceToCueBall)
        }?.trackID
    }
}

/// Which shooter-track appearance vectors may be held in session RAM, and whom they may teach
/// (research §7.2/§7.4). Samples only ever come from a gated shooter track, never from bystanders.
enum AppearanceLearning {
    /// Cosine to a player's session template above which a vector "plausibly is" them. Assumption; tune on replays.
    static let matchFloor = 0.65

    static func resemblance(_ sample: Embedding, _ templates: [Embedding]) -> Double {
        templates.compactMap { sample.cosine($0) }.max() ?? -1
    }

    /// Hold the vector (RAM, tap window only) if it resembles some clothes-consented player's template, or it was the
    /// gated shooter on a clothes-consented player's own turn at a table where *everyone* consented to clothes (so a
    /// tap can teach a changed look, S3/CX-8, without ever holding a guest's or non-consenting player's vector).
    /// Holding never teaches: nothing is learned from turn order or `.auto` (r2 BLOCKER 1); only the player's own
    /// registration capture or a one-tap confirmation naming a consented player does. Untapped vectors are dropped
    /// when the tap window closes, and at once on revoke.
    static func mayHold(_ sample: Embedding, roster: IdentityRoster, gallery: [UUID: [Embedding]],
                        expectedShooter: UUID? = nil) -> Bool {
        roster.clothesConsented.contains { resemblance(sample, gallery[$0] ?? []) >= matchFloor }
            || (expectedShooter.map { roster.contains($0) } ?? false && roster.entries.allSatisfy(\.consent.clothes))
    }
}
