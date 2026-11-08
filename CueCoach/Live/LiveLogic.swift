import CoreGraphics
import Foundation
import Geometry
import Rules
import Engine
import simd

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
    static func dashes(_ pts: [Vec2], dash: Double, gap: Double, skip: Double, max: Int) -> [(Vec2, Vec2)] {
        guard pts.count >= 2 else { return [] }
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

/// Post-shot rating from what the camera saw, run through the Rules engine (Codex r5: a foul is never "Good").
/// Uses the D18 classes (Engine.DecisionRating). When a live ShotEngine evaluation is wired, `Ratings.rate`
/// replaces the no-foul branch; fouls stay capped at Mistake/Blunder.
enum RuleRating {
    /// ShotOutcome for the Rules engine, following its contract (Codex r6): `ids` maps tracker ids → rule ball ids
    /// (cue = 0; unknown balls are absent). No contact *seen* is unknown (`noContact` stays false); rail-after-
    /// contact is `nil` because the camera record has no contact-vs-rail ordering; `pocketOrder` comes from observed
    /// drop times when known, else empty (= unknown) — never ball-number order.
    static func outcome(_ r: ShotRecord, ids: [Int: BallID], pocketTimes: [Int: Double]? = nil) -> ShotOutcome {
        var pocketed: [BallID: Pocket] = [:]
        for (tid, p) in r.pocketed { if let id = ids[tid] { pocketed[id] = p } }
        let first = r.firstContact.flatMap { ids[$0] }
        var order: [BallID] = []
        if let times = pocketTimes {
            order = r.pocketed.keys.filter { times[$0] != nil && ids[$0] != nil }
                .sorted { times[$0]! < times[$1]! }.compactMap { ids[$0] }
        }
        return ShotOutcome(firstContact: first, noContact: false, pocketed: pocketed, pocketOrder: order,
                           anyRailAfterContact: nil)
    }

    static func rate(_ r: ShotRecord, ids: [Int: BallID], engine: RulesEngine, game: GameState,
                     pocketTimes: [Int: Double]? = nil) -> (rating: DecisionRating, result: RuleResult) {
        let result = engine.apply(outcome(r, ids: ids, pocketTimes: pocketTimes), to: game)
        let shooter = game.shooter
        let rating: DecisionRating
        if !result.fouls.isEmpty {
            rating = (result.winner != nil && result.winner != shooter) ? .blunder : .mistake
        } else if result.winner == shooter {
            rating = .best
        } else if !result.turnPasses && r.pocketed.keys.contains(where: { $0 != r.cueID }) {
            rating = .good
        } else {
            rating = .okay
        }
        return (rating, result)
    }
}

/// Badge look (MASTER.md post-shot badge): SF Symbol + colour + ≤2 words.
struct BadgeStyle: Equatable, Sendable {
    var symbol: String
    var color: UInt32   // 0xRRGGBB
    var word: String

    static func of(_ r: DecisionRating) -> BadgeStyle {
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

/// Turns perception into the app shell's aim lifecycle (LiveSession.aimStarted / aimEnded / aimCancelled /
/// ballsSettled / settled). Pure, so the order is testable.
struct AimEvents: Sendable {
    enum Event: Equatable, Sendable { case aimStarted, aimEnded, aimCancelled, settled }
    enum Phase: Equatable, Sendable { case idle, aiming, moving }
    var cancelAfter = 1.0
    private(set) var phase: Phase = .idle
    private var cueLostAt: Double?

    mutating func update(cueVisible: Bool, atRest: Bool, shotStarted: Bool, shotEnded: Bool, at t: Double) -> [Event] {
        if shotEnded, phase == .moving || phase == .aiming {
            phase = .idle; cueLostAt = nil
            return [.settled]
        }
        if shotStarted, phase != .moving {
            let wasAiming = phase == .aiming
            phase = .moving; cueLostAt = nil
            // Balanced for the shell: an aim the cue detector missed still gets its aimStarted first.
            return wasAiming ? [.aimEnded] : [.aimStarted, .aimEnded]
        }
        switch phase {
        case .idle:
            if atRest && cueVisible { phase = .aiming; return [.aimStarted] }
        case .aiming:
            if cueVisible { cueLostAt = nil }
            else if let l = cueLostAt { if t - l > cancelAfter { phase = .idle; cueLostAt = nil; return [.aimCancelled] } }
            else { cueLostAt = t }
        case .moving:
            break
        }
        return []
    }
}

/// Manual fallback (user decision): tap the two corner pockets nearest you (any order); the table plane and the
/// size preset fill in the rest; then drag any corner (loupe + snap) and confirm.
enum TwoTapTable {
    /// - a, b: the two tapped near corner pockets (world, on the table plane). - viewer: camera position.
    /// - size: preset; nil = snap from the tapped width (width = length / 2).
    static func corners(_ a: SIMD3<Double>, _ b: SIMD3<Double>, viewer: SIMD3<Double>, size: TableSize?,
                        up: SIMD3<Double> = SIMD3(0, 1, 0)) -> [SIMD3<Double>]? {
        let n = simd_normalize(up)
        var ab = b - a; ab -= n * simd_dot(ab, n)
        let w = simd_length(ab)
        guard w > 0.4 else { return nil }
        let preset = size ?? TableSizing.snap(length: 2 * w, width: w).size
        let spec = TableSpec(size: preset)
        let mid = (a + b) / 2
        var dir = simd_normalize(simd_cross(n, ab / w))
        var toViewer = viewer - mid; toViewer -= n * simd_dot(toViewer, n)
        if simd_dot(dir, toViewer) > 0 { dir = -dir }   // the far end is away from the user
        let u = ab / w
        let halfW = spec.width / 2
        let a2 = mid - u * halfW, b2 = mid + u * halfW   // keep the tapped mid-line, preset width
        return [a2, b2, b2 + dir * spec.length, a2 + dir * spec.length]
    }
}

/// What Live tells the app shell (wired by `LiveScreenAdapter` to `LiveSession`). Defaults do nothing, so Live
/// runs standalone (then it draws its own post-shot badge).
struct LiveHooks {
    var aimStarted: @MainActor () -> Void = {}
    var aimEnded: @MainActor () -> Void = {}
    var aimCancelled: @MainActor () -> Void = {}
    var ballsSettled: @MainActor () -> Void = {}
    var settled: @MainActor (DecisionRating, Bool) -> Void = { _, _ in }
    /// The shell shows the post-shot badge itself; Live then doesn't.
    var shellShowsBadge = false
    /// The shell's active game (rules + state) for ratings and ring legality; nil = bar-8 open table.
    var currentGame: @MainActor () -> (RulesEngine, GameState)? = { nil }

    init() {}
    init(aimStarted: @escaping @MainActor () -> Void, aimEnded: @escaping @MainActor () -> Void,
         aimCancelled: @escaping @MainActor () -> Void, ballsSettled: @escaping @MainActor () -> Void,
         settled: @escaping @MainActor (DecisionRating, Bool) -> Void) {
        self.aimStarted = aimStarted; self.aimEnded = aimEnded; self.aimCancelled = aimCancelled
        self.ballsSettled = ballsSettled; self.settled = settled; shellShowsBadge = true
    }
}

/// Table-frame health and the remembered size.
enum TableHealth {
    /// Detected balls' apparent size vs 57.15 mm at the current pose: > 25 % off with a few balls = stale frame.
    static func isStale(ballScale: Double?, detections: Int) -> Bool {
        guard let s = ballScale, detections >= 3 else { return false }
        return abs(s - 1) > 0.25
    }

    static let measuredKey = "cc.table.measured"
    /// The app shell preselects this in setup (TableSize raw value).
    static func rememberMeasured(_ size: TableSize, defaults: UserDefaults = .standard) {
        defaults.set(size.rawValue, forKey: measuredKey)
    }
    static func measuredSize(defaults: UserDefaults = .standard) -> TableSize? {
        defaults.string(forKey: measuredKey).flatMap(TableSize.init(rawValue:))
    }
}

/// The coaching glyph's symbol (Codex r5: never a check before a real lock, however stable the ghost looks).
enum CoachingSymbol {
    static func of(failure: LockFailure?, locked: Bool) -> String {
        if locked { return "checkmark" }
        return failure?.symbol ?? "viewfinder"
    }
}

/// Preset ambiguity (matrix false lock: a 9 ft table locked as 8 ft). A measured length that sits well between two
/// presets isn't trusted yet — keep looking instead of locking the wrong size.
enum SizeAmbiguity {
    static func isAmbiguous(measuredLength m: Double, snapped: TableSize?, fraction: Double = 0.35) -> Bool {
        guard let snapped else { return false }   // measured size used directly (D12): nothing to confuse
        let presets = TableSize.allCases.map(\.playingLength).sorted()
        guard let i = presets.firstIndex(of: snapped.playingLength) else { return false }
        let neighbour = m >= snapped.playingLength ? (i + 1 < presets.count ? presets[i + 1] : nil) : (i > 0 ? presets[i - 1] : nil)
        guard let n = neighbour else { return false }
        return abs(m - snapped.playingLength) > fraction * abs(n - snapped.playingLength)
    }
}

/// Latches any non-normal ARKit tracking seen on any frame until the next status tick takes it (Codex r6: a
/// relocalization shorter than the 250 ms tick must still re-validate the table).
struct LimitedLatch: Sendable {
    private var seen = false
    mutating func note(trackingNormal: Bool) { if !trackingNormal { seen = true } }
    /// Returns whether a non-normal state was seen since the last call, and clears it.
    mutating func take() -> Bool { defer { seen = false }; return seen }
}
