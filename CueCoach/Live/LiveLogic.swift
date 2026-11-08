import CoreGraphics
import Foundation
import Geometry
import Rules

/// Screen state, shown with icon + colour only.
enum LiveStatus: Equatable, Sendable {
    case searching      // sweep the phone; no table plane yet
    case placing        // plane found; corners being placed/adjusted
    case confirming     // 4 corners placed, waiting for ✓
    case calibrated     // tracking the table
    case trackingLost   // AR tracking limited: dim overlay, pulse recalibrate
    case phoneMoved     // a bump: pulse recalibrate briefly
    case relocking      // after relocalization: overlay dimmed, no perception, until the table locks again

    static func derive(planeFound: Bool, corners: Int, calibrated: Bool, trackingOK: Bool, bumped: Bool,
                       relocking: Bool = false) -> LiveStatus {
        if calibrated {
            if !trackingOK { return .trackingLost }
            if relocking { return .relocking }
            if bumped { return .phoneMoved }
            return .calibrated
        }
        if corners >= 4 { return .confirming }
        if !planeFound && corners == 0 { return .searching }
        return .placing
    }

    var showsRecalibratePulse: Bool { self == .trackingLost || self == .phoneMoved || self == .relocking }
    /// World-anchored guidance and perception results are only trusted in this state.
    var trustsTable: Bool { self == .calibrated || self == .phoneMoved }
}

/// Phone bump detector from CoreMotion user acceleration (g) and rotation rate (rad/s).
struct BumpDetector: Sendable {
    var accelThreshold = 0.35
    var rotationThreshold = 1.6
    var holdSeconds = 2.0
    private(set) var lastBump: Double?

    /// Returns true while within `holdSeconds` of the last bump.
    mutating func update(userAcceleration: Double, rotationRate: Double, at t: Double) -> Bool {
        if userAcceleration > accelThreshold || rotationRate > rotationThreshold { lastBump = t }
        guard let b = lastBump else { return false }
        return t - b < holdSeconds
    }
}

/// Ring colour per ball (MASTER: legal green, illegal red, cue white).
enum TargetMark: Equatable, Sendable { case cue, legal, illegal, unknown }

enum TargetLegality {
    /// Bar-8 open table until the Rules wiring lands (game flow).
    static func defaultGame() -> (RulesEngine, GameState) {
        let engine = RulesEngine(ruleSet: .barEight)
        var g = engine.newGame()
        g.phase = .open
        g.ballInHand = .none
        return (engine, g)
    }

    static func mark(kind: BallKind, number: Int?, legal: Set<BallID>) -> TargetMark {
        if kind == .cue || number == 0 { return .cue }
        if let n = number, let id = BallID(n) { return legal.contains(id) ? .legal : .illegal }
        switch kind {
        case .eight: return legal.contains(.eight) ? .legal : .illegal
        case .solid: return legal.contains { $0.group == .solids } ? .legal : .illegal
        case .stripe: return legal.contains { $0.group == .stripes } ? .legal : .illegal
        default: return .unknown
        }
    }
}

/// Drops stale perception results: frames are numbered when dispatched; an epoch bumps whenever
/// tracking state changes or the table is (re)locked, so results from before it are discarded.
struct FrameOrdering: Sendable {
    private(set) var lastApplied = -1
    mutating func accept(seq: Int, epoch: Int, currentEpoch: Int) -> Bool {
        guard epoch == currentEpoch, seq > lastApplied else { return false }
        lastApplied = seq
        return true
    }
}

/// Turns sampled paths into drawable segments (bounded counts for entity pools).
enum OverlayPath {
    /// Simplify `pts` into at most `max` straight segments (keeps corners such as cushion bounces).
    static func segments(_ pts: [Vec2], max: Int, tolerance: Double = 0.004) -> [(Vec2, Vec2)] {
        guard pts.count >= 2 else { return [] }
        var keep = douglasPeucker(pts, tolerance)
        var tol = tolerance
        while keep.count - 1 > max && tol < 0.2 { tol *= 2; keep = douglasPeucker(pts, tol) }
        return zip(keep, keep.dropFirst()).map { ($0, $1) }
    }

    /// Dash pattern walked along the polyline, starting `skip` metres in.
    /// When the path is longer than `max` dashes cover, the pattern stretches so it still reaches the end.
    static func dashes(_ pts: [Vec2], dash dash0: Double, gap gap0: Double, skip: Double, max: Int) -> [(Vec2, Vec2)] {
        guard pts.count >= 2, max > 0 else { return [] }
        let total = zip(pts, pts.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let need = total - skip
        let stretch = need > 0 ? Swift.max(1, need / (Double(max) * (dash0 + gap0) - gap0)) : 1
        let dash = dash0 * stretch, gap = gap0 * stretch
        var out: [(Vec2, Vec2)] = []
        var along = 0.0, next = skip
        var drawing = false
        var start = pts[0]
        for (a, b) in zip(pts, pts.dropFirst()) {
            let len = a.distance(to: b)
            guard len > 1e-9 else { continue }
            let u = (b - a) / len
            var t = 0.0
            while along + (len - t) >= next {
                let step = next - along
                t += step; along = next
                let p = a + u * t
                if drawing { out.append((start, p)); if out.count >= max { return out }; next += gap }
                else { start = p; next += dash }
                drawing.toggle()
            }
            along += len - t
        }
        if drawing, let last = pts.last, start.distance(to: last) > 0.005, out.count < max { out.append((start, last)) }
        return out
    }

    static func douglasPeucker(_ p: [Vec2], _ eps: Double) -> [Vec2] {
        guard p.count > 2 else { return p }
        let a = p[0], b = p[p.count - 1], ab = b - a, l = ab.length
        var idx = 0, dmax = 0.0
        for i in 1..<(p.count - 1) {
            let d = l > 1e-12 ? abs(ab.cross(p[i] - a)) / l : p[i].distance(to: a)
            if d > dmax { dmax = d; idx = i }
        }
        guard dmax > eps else { return [a, b] }
        let left = douglasPeucker(Array(p[0...idx]), eps), right = douglasPeucker(Array(p[idx...]), eps)
        return left.dropLast() + right
    }
}

/// How the live cue line is drawn (SPEC §3: aiming at an illegal ball turns the line red).
enum LiveAimStyle: Equatable, Sendable {
    case neutral   // white
    case merged    // green: on the suggested line
    case illegal   // red #F87171 + pulsing red ring on the hit ball

    static func of(hitTrackID: Int?, marks: [Int: TargetMark], merged: Bool) -> LiveAimStyle {
        if let id = hitTrackID, marks[id] == .illegal { return .illegal }
        return merged ? .merged : .neutral
    }
}

/// Schmitt trigger for "live aim is on the suggested line", with a haptic cooldown so tremor near the
/// threshold doesn't chatter.
struct ConvergenceLatch: Sendable {
    var enter = 0.85
    var exit = 0.70
    var hapticCooldown = 0.3
    /// After leaving the line, it must stay off this long before entering can buzz again.
    var rearm = 1.0
    /// EMA weight on new samples (tremor smoothing before the thresholds).
    var smoothing = 0.3
    private(set) var merged = false
    private(set) var smoothed: Double?
    private var lastHaptic = -Double.infinity
    private var leftAt: Double?

    /// Returns whether a selection haptic should fire now.
    mutating func update(_ raw: Double, at t: Double) -> Bool {
        let c = smoothed.map { $0 + smoothing * (raw - $0) } ?? raw
        smoothed = c
        if !merged && c > enter {
            merged = true
            let armed = leftAt.map { t - $0 >= rearm } ?? true
            leftAt = nil
            if armed && t - lastHaptic >= hapticCooldown { lastHaptic = t; return true }
        } else if merged && c < exit {
            merged = false
            leftAt = t
        }
        return false
    }
}

/// Fires once when a condition becomes true; re-arms only after it has stayed false for `rearm` seconds
/// (so a flickering detection can't repeat the warning).
struct EntryLatch: Sendable {
    var rearm = 0.6
    private var active = false
    private var falseSince: Double?

    mutating func update(_ on: Bool, at t: Double) -> Bool {
        if on {
            falseSince = nil
            if !active { active = true; return true }
            return false
        }
        if active {
            if falseSince == nil { falseSince = t }
            if let f = falseSince, t - f >= rearm { active = false; falseSince = nil }
        }
        return false
    }
}

/// Ball-ring look: shape carries meaning too (never colour alone, MASTER.md), animation stays calm.
struct RingStyle: Equatable, Sendable {
    enum Shape: Equatable, Sendable { case solid, dashed }
    var shape: Shape
    var alpha: Double
    var scale: Double

    /// - turnAge: seconds since the turn started (table at rest after a shot, or just locked).
    /// - targeted: the live cue line is pointing at this ball.
    static func of(_ mark: TargetMark, turnAge: Double, time t: Double, targeted: Bool = false) -> RingStyle {
        switch mark {
        case .cue:
            return RingStyle(shape: .solid, alpha: 0.95, scale: 1.1)
        case .unknown:
            return RingStyle(shape: .solid, alpha: 0.35, scale: 1)
        case .legal:
            // One pulse at turn start (0…1.2 s), then faint.
            let faint = 0.35
            guard turnAge >= 0, turnAge < 1.2 else { return RingStyle(shape: .solid, alpha: faint, scale: 1) }
            let bump = sin(.pi * turnAge / 1.2)
            return RingStyle(shape: .solid, alpha: faint + (0.9 - faint) * bump, scale: 1 + 0.12 * bump)
        case .illegal:
            // Dashed, slow alpha breathing; faster and larger when the player is aiming at it.
            let period = targeted ? 0.8 : 1.8
            let phase = 0.5 + 0.5 * sin(2 * .pi * t / period)
            return RingStyle(shape: .dashed, alpha: targeted ? 0.6 + 0.4 * phase : 0.4 + 0.3 * phase,
                             scale: targeted ? 1 + 0.15 * phase : 1)
        }
    }
}

/// D24: what the live screen is for. The app shell passes this to `LiveScreen(mode:)`.
enum LiveMode: Equatable, Sendable {
    /// A real game: rules helpers only (showing the shot would be cheating), post-shot rating badge.
    case game
    /// Coaching: suggested Line 1 + Line 2; Line 3 (cue path) and the spin/power dock from level 3.
    case training(level: Int)
}

/// Visibility matrix per mode (D24).
struct OverlayVisibility: Equatable, Sendable {
    var line1: Bool            // suggested cue → ghost
    var line2: Bool            // suggested object → pocket
    var line3: Bool            // suggested cue path after contact
    var suggestedGhost: Bool
    var shotDock: Bool         // spin face + power meter
    var liveCueLine: Bool      // the player's own cue line
    var legalRings: Bool
    var illegalWarning: Bool   // red pulsing ring + one buzz when the cue points at an illegal ball
    var ratingBadge: Bool

    static func of(_ mode: LiveMode) -> OverlayVisibility {
        switch mode {
        case .game:
            OverlayVisibility(line1: false, line2: false, line3: false, suggestedGhost: false, shotDock: false,
                              liveCueLine: false, legalRings: true, illegalWarning: true, ratingBadge: true)
        case .training(let level):
            OverlayVisibility(line1: true, line2: true, line3: level >= 3, suggestedGhost: true, shotDock: level >= 3,
                              liveCueLine: true, legalRings: true, illegalWarning: true, ratingBadge: false)
        }
    }
}

/// Placeholder post-shot rating until the Engine (D18) is wired: derived from what the camera saw.
enum PlaceholderRating {
    static func rate(_ r: ShotRecord) -> DecisionRatingLite {
        if r.pocketed[r.cueID] != nil { return .mistake }                 // scratch
        if r.pocketed.keys.contains(where: { $0 != r.cueID }) { return .good }
        if r.firstContact != nil { return .okay }
        return .inaccuracy                                              // no contact
    }
}

/// D18 classes (mirrors Engine.DecisionRating; kept local so Live doesn't depend on Engine yet).
enum DecisionRatingLite: String, CaseIterable, Sendable {
    case brilliant, great, best, good, okay, book, inaccuracy, miss, mistake, blunder
}

/// Badge look (MASTER.md post-shot badge): SF Symbol + colour + ≤2 words.
struct BadgeStyle: Equatable, Sendable {
    var symbol: String
    var color: UInt32   // 0xRRGGBB
    var word: String

    static func of(_ r: DecisionRatingLite) -> BadgeStyle {
        switch r {
        case .brilliant: BadgeStyle(symbol: "sparkles", color: 0x22D3EE, word: "Brilliant")
        case .great: BadgeStyle(symbol: "star.fill", color: 0x4ADE80, word: "Great")
        case .best: BadgeStyle(symbol: "checkmark.seal.fill", color: 0x4ADE80, word: "Best")
        case .good: BadgeStyle(symbol: "checkmark", color: 0xF2F5F3, word: "Good")
        case .okay: BadgeStyle(symbol: "hand.thumbsup", color: 0xF2F5F3, word: "Okay")
        case .book: BadgeStyle(symbol: "book.fill", color: 0xF2F5F3, word: "Book")
        case .inaccuracy: BadgeStyle(symbol: "exclamationmark", color: 0xFACC15, word: "Inaccuracy")
        case .miss: BadgeStyle(symbol: "circle.dashed", color: 0xFACC15, word: "Miss")
        case .mistake: BadgeStyle(symbol: "questionmark", color: 0xFB923C, word: "Mistake")
        case .blunder: BadgeStyle(symbol: "xmark", color: 0xF87171, word: "Blunder")
        }
    }
}

/// Glyph for each lock failure (icon only, no text).
extension LockFailure {
    var symbol: String {
        switch self {
        case .noPlane: "iphone.gen3"                                   // sweep the phone
        case .noFelt: "rectangle.dashed"                               // point at the cloth
        case .partialTable, .tooClose: "arrow.up.left.and.arrow.down.right"  // step back / tilt to fit it all
        case .tooFar: "arrow.down.right.and.arrow.up.left"             // move closer
        case .badShape: "viewfinder"
        case .unstable: "hand.raised"                                  // hold steady
        }
    }
}

/// When to offer the corner fallback (lock plan step 7): unlocked for ~4 s, or stuck on the same reason for 2.5 s —
/// with or without a plane.
enum FallbackPolicy {
    static func offer(unlockedFor: Double?, sameFailureFor: Double?, unlockedLimit: Double = 4, sameLimit: Double = 2.5) -> Bool {
        if let u = unlockedFor, u > unlockedLimit { return true }
        if let f = sameFailureFor, f > sameLimit { return true }
        return false
    }
}

/// How long the locator has reported the same failure.
struct FailureTimer: Sendable {
    private(set) var current: LockFailure?
    private var since: Double?

    mutating func note(_ f: LockFailure?, at t: Double) {
        if f != current { current = f; since = f == nil ? nil : t }
    }

    func sameFor(at t: Double) -> Double? { since.map { t - $0 } }
}

/// Drag snapping for corner correction: snap to the nearest candidate (rail/pocket corner) within `radius` points.
enum DragSnap {
    static func snap(_ p: CGPoint, to targets: [CGPoint], radius: CGFloat) -> CGPoint? {
        let best = targets.min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }
        guard let b = best, hypot(b.x - p.x, b.y - p.y) <= radius else { return nil }
        return b
    }
}
