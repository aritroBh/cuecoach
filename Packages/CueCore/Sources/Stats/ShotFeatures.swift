import Foundation
import Geometry

// Per-shot classification (docs/SPEC.md §6, docs/SCHEMA.md `Shot.features`).
// Raw values are persisted by the app (`StoredShotFeatures`) — never rename a case.

/// Cut angle between the cue-ball aim line (cue → ghost ball) and the object-ball line (object → target).
/// Buckets are lower-bound inclusive: 15° is `c15to30`.
public enum CutBucket: String, CaseIterable, Codable, Sendable {
    case c0to15, c15to30, c30to45, c45to60, c60plus

    public init(degrees: Double) {
        guard degrees.isFinite else { self = .c0to15; return }
        switch degrees {
        case ..<15: self = .c0to15
        case ..<30: self = .c15to30
        case ..<45: self = .c30to45
        case ..<60: self = .c45to60
        default: self = .c60plus
        }
    }

    /// Thin cuts (≥ 45°): the "Cut Artist" archetype dimension.
    public var isThin: Bool { self == .c45to60 || self == .c60plus }
}

/// Total ball travel the shot needs (cue → ghost ball + object → pocket), as a fraction of the
/// playing length so it means the same on 7, 8 and 9 ft tables.
public enum DistanceBucket: String, CaseIterable, Codable, Sendable {
    case short, mid, long

    public init(path: Double, tableLength: Double, _ t: FeatureThresholds = .standard) {
        let f = tableLength > 0 ? path / tableLength : 0
        if !(f >= t.midFromLengthFraction) { self = .short }
        else if f < t.longFromLengthFraction { self = .mid }
        else { self = .long }
    }
}

public enum PocketType: String, CaseIterable, Codable, Sendable {
    case corner, side
    public init(_ p: Pocket) { self = p.isSide ? .side : .corner }
}

/// One kind per shot (the app persists a single value). Precedence when several apply:
/// safety > jump > kick > combo > bank > rail > plain.
public enum ShotKind: String, CaseIterable, Codable, Sendable {
    case plain, bank, combo, kick, rail, jump, safety
}

/// Tunable classification thresholds (house defaults — not from the spec; see docs/DECISIONS.md once approved).
public struct FeatureThresholds: Hashable, Codable, Sendable {
    /// Path ≥ this × table length is `mid`.
    public var midFromLengthFraction: Double
    /// Path ≥ this × table length is `long`.
    public var longFromLengthFraction: Double
    /// Target ball whose centre is within ballRadius + this of a cushion nose counts as a rail shot.
    public var railGap: Double

    public init(midFromLengthFraction: Double = 0.4, longFromLengthFraction: Double = 0.9,
                railGap: Double = TableSpec.ballRadius / 2) {
        self.midFromLengthFraction = midFromLengthFraction
        self.longFromLengthFraction = longFromLengthFraction
        self.railGap = railGap
    }

    public static let standard = FeatureThresholds()
}

/// Ordered observation of a shot — what the physics `ShotTrace` or the vision tracker saw.
/// Stats does not depend on Physics, so callers map `ShotTrace.events` into this.
public enum TraceEvent: Hashable, Codable, Sendable {
    case ballBall(BallID, BallID)
    case cushion(BallID)
    case pocket(BallID, Pocket)
    /// The ball left the cloth (jump shot when it is the cue ball before first contact).
    case airborne(BallID)
}

public struct ShotTraceSummary: Hashable, Codable, Sendable {
    /// Events in time order.
    public var events: [TraceEvent]
    public init(events: [TraceEvent]) { self.events = events }
}

/// What the shooter meant to do, when known (called ball/pocket, engine's chosen candidate, called safety).
public struct ShotIntent: Hashable, Codable, Sendable {
    public var target: BallID?
    public var pocket: Pocket?
    public var isSafety: Bool
    public init(target: BallID? = nil, pocket: Pocket? = nil, isSafety: Bool = false) {
        self.target = target
        self.pocket = pocket
        self.isSafety = isSafety
    }
    public static let unknown = ShotIntent()
}

public struct ShotFeatures: Hashable, Codable, Sendable {
    public var cutBucket: CutBucket
    public var distanceBucket: DistanceBucket
    public var pocketType: PocketType
    public var kind: ShotKind

    public init(cutBucket: CutBucket, distanceBucket: DistanceBucket, pocketType: PocketType, kind: ShotKind) {
        self.cutBucket = cutBucket
        self.distanceBucket = distanceBucket
        self.pocketType = pocketType
        self.kind = kind
    }

    public static let neutral = ShotFeatures(cutBucket: .c0to15, distanceBucket: .short, pocketType: .corner, kind: .plain)

    /// Cut angle in degrees [0, 180] for sending `object` toward `target` from `cue`.
    public static func cutAngleDegrees(cue: Vec2, object: Vec2, target: Vec2) -> Double {
        let toTarget = (target - object).normalized
        let ghost = object - toTarget * (2 * TableSpec.ballRadius)
        let aim = (ghost - cue).normalized
        guard aim != .zero, toTarget != .zero else { return 0 }
        let c = max(-1, min(1, aim.dot(toTarget)))
        return acos(c) * 180 / .pi
    }

    /// Classifies one competitive shot. Total: never traps; unknowns fall back to `neutral` fields.
    /// - Parameters:
    ///   - pre: table before the stroke; `post`: table at rest after it.
    ///   - trace: ordered events (physics or tracker).
    ///   - intent: called ball/pocket/safety when known; otherwise inferred from the trace and geometry.
    public static func extract(pre: TableState, post: TableState, trace: ShotTraceSummary,
                               intent: ShotIntent = .unknown, thresholds: FeatureThresholds = .standard) -> ShotFeatures {
        guard let cue = pre.balls[.cue]?.position else { return neutral }
        let spec = pre.spec
        let events = trace.events
        let onTable = pre.onTable.filter { !$0.key.isCue }
        guard !onTable.isEmpty else { return intent.isSafety ? withKind(.safety) : neutral }

        // First object ball the cue ball touched, and where in the event list.
        let firstContactIndex = events.firstIndex { if case .ballBall(let a, let b) = $0 { a.isCue || b.isCue } else { false } }
        let firstContact: BallID? = firstContactIndex.flatMap { i -> BallID? in
            guard case .ballBall(let a, let b) = events[i] else { return nil }
            return a.isCue ? b : a
        }
        let pocketOf: [BallID: Pocket] = events.reduce(into: [:]) { m, e in
            if case .pocket(let ball, let p) = e, m[ball] == nil { m[ball] = p }
        }
        func pocketEventIndex(_ ball: BallID) -> Int? {
            events.firstIndex { if case .pocket(let x, _) = $0 { x == ball } else { false } }
        }
        /// Index of the first object–object collision involving `ball`.
        func objectHitIndex(_ ball: BallID) -> Int? {
            events.firstIndex {
                if case .ballBall(let a, let b) = $0 { !a.isCue && !b.isCue && (a == ball || b == ball) } else { false }
            }
        }

        // Combo inferred: some pocketed object ball ≠ first contact that was struck by another object ball first.
        var inferredCombo: BallID?
        if intent.target == nil, let f = firstContact {
            let candidates = pocketOf.keys.filter { !$0.isCue && $0 != f }.sorted()
            inferredCombo = candidates.first { ball in
                guard let hit = objectHitIndex(ball) else { return false }
                return hit < (pocketEventIndex(ball) ?? Int.max)
            }
        }

        let target: BallID = intent.target ?? inferredCombo ?? firstContact
            ?? onTable.min { $0.value.position.distance(to: cue) < $1.value.position.distance(to: cue) }!.key
        guard let targetPos = pre.balls[target]?.position else { return neutral }
        let isCombo = firstContact.map { $0 != target } ?? false
        let firstPos = firstContact.flatMap { pre.balls[$0]?.position }

        // Pocket: called/intended → observed → easiest by geometry.
        let pocket: Pocket = intent.pocket ?? pocketOf[target] ?? spec.pockets.min { p, q in
            cutAngleDegrees(cue: isCombo ? (firstPos ?? cue) : cue, object: targetPos, target: spec.pocketCenter(p))
                < cutAngleDegrees(cue: isCombo ? (firstPos ?? cue) : cue, object: targetPos, target: spec.pocketCenter(q))
        }!
        let pocketPos = spec.pocketCenter(pocket)

        // Cut and travel: for a combo, the cut is on the first ball toward the target ball.
        let cut: Double
        let path: Double
        if isCombo, let fp = firstPos {
            cut = cutAngleDegrees(cue: cue, object: fp, target: targetPos)
            path = ghost(fp, toward: targetPos).distance(to: cue) + fp.distance(to: targetPos) + targetPos.distance(to: pocketPos)
        } else {
            cut = cutAngleDegrees(cue: cue, object: targetPos, target: pocketPos)
            path = ghost(targetPos, toward: pocketPos).distance(to: cue) + targetPos.distance(to: pocketPos)
        }

        // Kind, by precedence.
        let beforeContact = events[..<(firstContactIndex ?? events.endIndex)]
        let kind: ShotKind
        if intent.isSafety {
            kind = .safety
        } else if beforeContact.contains(.airborne(.cue)) {
            kind = .jump
        } else if beforeContact.contains(.cushion(.cue)) {
            kind = .kick
        } else if isCombo {
            kind = .combo
        } else if isBank(target, events: events, contact: firstContactIndex, pocketIndex: pocketEventIndex(target)) {
            kind = .bank
        } else if distanceToNearestCushion(targetPos, spec) <= TableSpec.ballRadius + thresholds.railGap {
            kind = .rail
        } else {
            kind = .plain
        }

        return ShotFeatures(cutBucket: CutBucket(degrees: cut),
                            distanceBucket: DistanceBucket(path: path, tableLength: spec.length, thresholds),
                            pocketType: PocketType(pocket), kind: kind)
    }

    private static func withKind(_ k: ShotKind) -> ShotFeatures {
        var f = neutral; f.kind = k; return f
    }

    private static func ghost(_ object: Vec2, toward target: Vec2) -> Vec2 {
        object - (target - object).normalized * (2 * TableSpec.ballRadius)
    }

    /// Bank = the target ball touched a cushion after it was struck and before it dropped.
    private static func isBank(_ target: BallID, events: [TraceEvent], contact: Int?, pocketIndex: Int?) -> Bool {
        guard let c = contact, let p = pocketIndex, c < p else { return false }
        return events[(c + 1)..<p].contains(.cushion(target))
    }

    private static func distanceToNearestCushion(_ p: Vec2, _ spec: TableSpec) -> Double {
        min(p.x, spec.length - p.x, p.y, spec.width - p.y)
    }
}
