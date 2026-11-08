import Foundation
import Geometry

/// What the camera saw during one shot (SPEC §5.3). Ball identities are tracker ids until ML identity lands.
struct ShotRecord: Sendable, Equatable {
    var start: Double
    var end: Double
    var preState: [Int: Vec2]
    var finalState: [Int: Vec2]
    var cueID: Int
    /// First object-ball track the cue ball touched (nil = no contact seen).
    var firstContact: Int?
    /// Cushion contacts in time order (track id, rail). Capped at `ShotSegmenter.maxRails`.
    var rails: [(id: Int, rail: Rail)]
    /// Balls whose last measured path ran into a pocket mouth and that never came back.
    var pocketed: [Int: Pocket]
    /// Balls that vanished away from any pocket and never came back before the hard cap.
    var missing: Set<Int> = []
    /// Balls last seen rolling slowly into a pocket's jaws that may still be hanging there (the detector can't
    /// see inside the jaws): neither pocketed nor missing.
    var uncertainPockets: [Int: Pocket] = [:]
    /// Estimated drop time of each pocketed ball (s, same clock as start/end), for the pocketing order.
    var pocketTimes: [Int: Double] = [:]

    static func == (a: ShotRecord, b: ShotRecord) -> Bool {
        a.start == b.start && a.end == b.end && a.preState == b.preState && a.finalState == b.finalState
            && a.cueID == b.cueID && a.firstContact == b.firstContact && a.pocketed == b.pocketed
            && a.rails.map(\.id) == b.rails.map(\.id) && a.rails.map(\.rail) == b.rails.map(\.rail)
            && a.missing == b.missing && a.uncertainPockets == b.uncertainPockets && a.pocketTimes == b.pocketTimes
    }
}

enum Rail: String, Sendable { case head, foot, left, right }

protocol ShotSegmenting: Sendable {
    /// Feed every tracker update; returns a record when a shot ends.
    /// `strokeRecent`: true = the cue stick was seen stroking; false = the cue is visible but hasn't stroked
    /// (then nothing starts a shot: a hand nudge); nil = no cue stick in view.
    mutating func update(tracks: [TrackedBall], cueID: Int?, atRest: Bool, at t: Double, strokeRecent: Bool?) -> ShotRecord?
    var inShot: Bool { get }
}

/// SPEC §5.3: a shot starts right after a stroke and ends when every ball has been at rest for N frames.
///
/// Start evidence. With the cue stick in view, a detected stroke plus cue-ball speed over 2 frames. Without
/// it (nil), the kinematic stroke: the cue ball, tracked without a break since the last at-rest snapshot,
/// leaves its rest anchor by more than `startDisplacement` for `startFrames` frames. Rest jitter, a re-born
/// track (occlusion, hand placement, relocalization), or a track that wasn't in the snapshot never starts one.
///
/// End. The tracker is at rest, it was seen out of rest during the shot (or the shot is older than
/// `minRestedShot`), and every pre-shot ball is visible, confirmed pocketed, or missing past `vanishTimeout`.
struct ShotSegmenter: ShotSegmenting {
    var spec: TableSpec
    var startSpeed = 0.10      // m/s (stroke-gated start; also "object ball moving" for first contact)
    var startFrames = 2
    /// m from the rest anchor: the cue ball has really left (2 ball radii).
    var startDisplacement = 2 * TableSpec.ballRadius
    /// m: back inside this the start count resets (hysteresis).
    var resetDisplacement = TableSpec.ballRadius
    var contactSlack = 0.012   // m beyond 2R
    var railSlack = 0.012      // m beyond R from the nose line
    var movingSpeed = 0.08     // m/s: a ball counts as having moved this shot
    /// s: a pre-shot or moving ball that is unaccounted for blocks the end this long, then the record
    /// closes with it listed in `missing` (never silently dropped).
    var vanishTimeout = 8.0
    var pocketEntrySpeed = 0.1 // m/s toward the pocket when last measured
    /// s a ball must stay gone after heading into a pocket before it counts as pocketed.
    var pocketConfirm = 0.4
    /// s: a shot during which the tracker never left rest may still end after this long.
    var minRestedShot = 1.0
    /// s: without the cue stick in view, the cue ball must get from 1R to 2R off its anchor this fast (a stroke
    /// leaves rest impulsively; a hand pushing or placing it does not).
    var maxDepartTime = 0.15
    /// m: a confirmed-pocketed id seen again farther than this from its pocket is another object, not the ball.
    var pocketReturnRadius = 0.15
    /// s a confirmed-pocketed ball must stay in view near its pocket before it is un-pocketed (a reflection or a
    /// false positive in the jaws flickers; a ball that was only hidden stays).
    var pocketReturnHold = 0.5
    /// m/s²: rolling deceleration (CueCore Physics: μ_roll 0.01 × g).
    var rollingDecel = 0.01 * 9.81
    /// s a ball lost slowly in a pocket's jaws is waited for before it is recorded as uncertain.
    var jawsSettle = 1.0
    /// m: a ball this close to a pocket centre when lost at crawling speed may be hanging in the jaws.
    var jawsRadius = 0.10
    static let maxRails = 64
    /// Per-shot bookkeeping for balls that are neither pre-shot nor still around is dropped after this.
    var forgetAfter = 2.0

    private(set) var inShot = false
    private var fastFrames = 0
    private var farFrames = 0
    private var leftAt: Double?
    private var farAt: Double?
    private var lastRest: [Int: Vec2] = [:]
    private var lastRestT = -Double.infinity
    private var record: ShotRecord?
    private var lastSeen: [Int: (pos: Vec2, t: Double)] = [:]
    private var lastVel: [Int: Vec2] = [:]
    private var moved: Set<Int> = []
    private var vanishedAt: [Int: Double] = [:]
    private var pendingPocket: [Int: (pocket: Pocket, t: Double, certain: Bool, drop: Double)] = [:]
    /// Last few measured positions per id (speed from positions, not the filter).
    private var hist: [Int: [(p: Vec2, t: Double)]] = [:]
    /// When a confirmed-pocketed id started being seen again near its pocket.
    private var returnSince: [Int: Double] = [:]
    private var sawUnrest = false

    init(spec: TableSpec) { self.spec = spec }

    mutating func update(tracks: [TrackedBall], cueID: Int?, atRest: Bool, at t: Double,
                         strokeRecent: Bool? = nil) -> ShotRecord? {
        let confirmed = tracks.filter(\.confirmed)
        if !inShot {
            if atRest {
                // The tracker's at-rest lags motion onset by a few frames: a ball already moving keeps its old
                // anchor instead of dragging it along (the tracker reports exactly zero velocity when still).
                var anchor: [Int: Vec2] = [:]
                for b in confirmed where b.measured {
                    if b.velocity == .zero { anchor[b.id] = b.measuredPosition } else if let old = lastRest[b.id] { anchor[b.id] = old }
                }
                lastRest = anchor
                lastRestT = t
            }
            guard let cueID, let cue = confirmed.first(where: { $0.id == cueID }), cue.measured,
                  let anchor = lastRest[cueID], cue.measuredSince <= lastRestT, strokeRecent != false
            else { fastFrames = 0; farFrames = 0; leftAt = nil; farAt = nil; return nil }
            // Kinematic stroke: displacement from the rest anchor, with hysteresis.
            let disp = cue.measuredPosition.distance(to: anchor)
            if disp > resetDisplacement { if leftAt == nil { leftAt = t } } else { leftAt = nil; farAt = nil }
            if disp > startDisplacement { farFrames += 1; if farAt == nil { farAt = t } } else if disp <= resetDisplacement { farFrames = 0 }
            let impulsive = strokeRecent == true || (farAt.map { $0 - (leftAt ?? $0) <= maxDepartTime } ?? false)
            // Detected stroke: speed right after it (SPEC §5.3).
            fastFrames = strokeRecent == true && cue.speed > startSpeed ? fastFrames + 1 : 0
            guard (farFrames >= startFrames && impulsive) || fastFrames >= startFrames else { return nil }
            inShot = true
            let start = min(t, leftAt ?? t)
            fastFrames = 0; farFrames = 0; leftAt = nil; farAt = nil
            record = ShotRecord(start: start, end: start, preState: lastRest, finalState: [:], cueID: cueID, firstContact: nil,
                                rails: [], pocketed: [:])
            lastSeen = [:]; lastVel = [:]; moved = []; vanishedAt = [:]; pendingPocket = [:]; hist = [:]; returnSince = [:]
            sawUnrest = !atRest
        }
        guard var rec = record else { return nil }
        if !atRest { sawUnrest = true }
        let R = TableSpec.ballRadius
        // Visible = confirmed and measured this frame; coasting predictions are never evidence.
        // A confirmed-pocketed id that turns up far from its pocket is an impostor (another ball or a false
        // positive that inherited the id): ignored for this shot. Near the pocket it was in the jaws: un-pocket.
        // A confirmed-pocketed id seen again counts only after it has stayed in view near its pocket (it was in the
        // jaws, hidden) for `pocketReturnHold`; farther away, or flickering, it is an impostor: ignored this shot.
        var visible: [TrackedBall] = []
        for b in confirmed where b.measured {
            guard let pk = rec.pocketed[b.id] else { visible.append(b); continue }
            guard b.measuredPosition.distance(to: spec.pocketCenter(pk)) <= pocketReturnRadius else { returnSince[b.id] = nil; continue }
            let since = returnSince[b.id] ?? t
            returnSince[b.id] = since
            if t - since >= pocketReturnHold { visible.append(b) }
        }
        for id in returnSince.keys where !confirmed.contains(where: { $0.id == id && $0.measured }) { returnSince[id] = nil }
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // First contact: an object ball near the cue ball starts moving.
        if rec.firstContact == nil, let cue = byID[rec.cueID] {
            for b in visible where b.id != rec.cueID && b.speed > startSpeed {
                let start = rec.preState[b.id] ?? b.measuredPosition
                if cue.measuredPosition.distance(to: b.measuredPosition) < 2 * R + contactSlack + b.speed * 0.05
                    || cue.measuredPosition.distance(to: start) < 2 * R + contactSlack + 0.03 {
                    rec.firstContact = b.id
                    break
                }
            }
        }
        // Rails: a moving ball's normal velocity reverses near a cushion nose line.
        for b in visible {
            let p = b.measuredPosition
            if let pv = lastVel[b.id], pv.length > movingSpeed, rec.rails.count < Self.maxRails {
                let v = b.velocity
                func near(_ d: Double) -> Bool { d < R + railSlack + 0.02 }
                var hit: Rail?
                if near(p.x) && pv.x < -0.05 && v.x >= 0 { hit = .head }
                else if near(spec.length - p.x) && pv.x > 0.05 && v.x <= 0 { hit = .foot }
                else if near(p.y) && pv.y < -0.05 && v.y >= 0 { hit = .left }
                else if near(spec.width - p.y) && pv.y > 0.05 && v.y <= 0 { hit = .right }
                if let hit, rec.rails.last.map({ $0.id != b.id || $0.rail != hit }) ?? true { rec.rails.append((b.id, hit)) }
            }
            lastVel[b.id] = b.velocity
            lastSeen[b.id] = (p, t)
            hist[b.id, default: []].append((p, t))
            if hist[b.id]!.count > 4 { hist[b.id]!.removeFirst() }
            if b.speed > movingSpeed { moved.insert(b.id) }
            vanishedAt[b.id] = nil
            // Came back: it was not pocketed after all (a hand over the corner, one missed frame).
            pendingPocket[b.id] = nil
            rec.pocketed[b.id] = nil
            rec.pocketTimes[b.id] = nil
            rec.uncertainPockets[b.id] = nil
            returnSince[b.id] = nil
        }
        // Gone: a ball whose last measured path runs into a pocket mouth is a pocket candidate, confirmed once
        // it stays gone; any other absence (pre-shot balls never seen this shot included) is a vanish.
        let watched = Set(rec.preState.keys).union(lastSeen.keys)
        let alive = Set(tracks.map(\.id))   // includes coasting tracks the tracker hasn't given up on
        for id in watched where byID[id] == nil {
            if rec.pocketed[id] != nil || rec.uncertainPockets[id] != nil { continue }
            if let pend = pendingPocket[id] {
                if pend.certain {
                    if t - pend.t >= pocketConfirm || !alive.contains(id) {
                        rec.pocketed[id] = pend.pocket; rec.pocketTimes[id] = pend.drop; pendingPocket[id] = nil
                    }
                } else if t - pend.t >= jawsSettle {
                    // Stayed gone through the settle window, but it was too slow to be sure it dropped.
                    rec.uncertainPockets[id] = pend.pocket; pendingPocket[id] = nil
                }
                continue
            }
            if vanishedAt[id] == nil {
                if let seen = lastSeen[id], let verdict = pocketVerdict(id, from: seen.pos, at: seen.t) {
                    pendingPocket[id] = (verdict.pocket, t, verdict.certain, verdict.drop)
                    if verdict.certain && !alive.contains(id) {
                        rec.pocketed[id] = verdict.pocket; rec.pocketTimes[id] = verdict.drop; pendingPocket[id] = nil
                    }
                } else {
                    vanishedAt[id] = lastSeen[id] == nil ? rec.start : t
                }
            }
        }
        // E1: forget short-lived tracks (false positives) that are neither pre-shot balls nor still around.
        for (id, seen) in lastSeen where rec.preState[id] == nil && byID[id] == nil && t - seen.t > forgetAfter {
            lastSeen[id] = nil; lastVel[id] = nil; vanishedAt[id] = nil; moved.remove(id); pendingPocket[id] = nil; hist[id] = nil
        }
        record = rec
        // The tracker's at-rest only covers balls it still sees. A pre-shot ball (or one that moved) that is
        // gone blocks the end until it is back, pocketed, or the timeout passes.
        let mustAccount = Set(rec.preState.keys).union(moved)
        let gone = mustAccount.filter { byID[$0] == nil && rec.pocketed[$0] == nil && rec.uncertainPockets[$0] == nil }
        let unresolved = gone.contains { id in
            if pendingPocket[id] != nil { return true }
            return t - (vanishedAt[id] ?? t) < vanishTimeout
        }
        guard atRest, t > rec.start, sawUnrest || t - rec.start >= minRestedShot, !unresolved else { return nil }
        rec.missing = Set(gone.filter { pendingPocket[$0] == nil })
        rec.end = t
        rec.finalState = Dictionary(visible.map { ($0.id, $0.measuredPosition) }, uniquingKeysWith: { a, _ in a })
        inShot = false
        record = nil
        lastRest = rec.finalState
        lastRestT = t
        lastSeen = [:]; lastVel = [:]; moved = []; vanishedAt = [:]; pendingPocket = [:]; hist = [:]; returnSince = [:]
        return rec
    }

    /// Pocket verdict for a ball that just went out of view: heading through a mouth fast enough to roll past
    /// the pocket centre = certain (with an estimated drop time); too slow to get there, or crawling within
    /// `jawsRadius` of a pocket, = may be hanging in the jaws (uncertain).
    func pocketVerdict(_ id: Int, from p: Vec2, at seenT: Double) -> (pocket: Pocket, certain: Bool, drop: Double)? {
        let v = lastVel[id] ?? .zero
        var speed = v.length
        if let h = hist[id], h.count >= 2, let a = h.first, let b = h.last, b.t > a.t {
            speed = min(speed, b.p.distance(to: a.p) / (b.t - a.t))   // positions, not filter lag
        }
        if let pk = pocketEntered(from: p, velocity: v) {
            let along = max(0, (spec.pocketCenter(pk) - p).dot(v.normalized))
            let rolls = speed * speed / (2 * rollingDecel)
            let certain = rolls >= along + 0.03
            return (pk, certain, seenT + (speed > 0 ? along / speed : 0))
        }
        // Crawling into the jaws (not rolling away from the pocket: a nudge out, then an arm over it, is a vanish).
        if let pk = spec.pockets.first(where: { p.distance(to: spec.pocketCenter($0)) < jawsRadius }), speed <= pocketEntrySpeed,
           v.dot(spec.pocketCenter(pk) - p) >= 0 {
            return (pk, false, seenT)
        }
        return nil
    }

    /// The pocket whose mouth the ball's last measured path runs into (segment from the last measurement along
    /// its velocity, a few frames long). The detector loses balls ~6 cm before the pocket centre, so the last
    /// measurement itself is outside any small capture zone at speed.
    func pocketEntered(from p: Vec2, velocity v: Vec2) -> Pocket? {
        let speed = v.length
        guard speed > pocketEntrySpeed else { return nil }
        let u = v / speed
        let reach = min(0.35, 0.07 + speed * 4.0 / 30)
        let best = spec.pockets.compactMap { pk -> (Pocket, Double)? in
            let c = spec.pocketCenter(pk)
            let along = (c - p).dot(u)
            guard along > 0, along <= reach + 0.03 else { return nil }
            let off = (c - (p + u * along)).length
            let mouth = (pk.isSide ? spec.sideMouth : spec.cornerMouth) / 2
            return off <= mouth ? (pk, off) : nil
        }
        return best.min { $0.1 < $1.1 }?.0
    }
}
