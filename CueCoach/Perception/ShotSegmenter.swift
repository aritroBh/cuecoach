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
    /// Cushion contacts in time order (track id, rail).
    var rails: [(id: Int, rail: Rail)]
    /// Tracks that disappeared inside a pocket's capture zone.
    var pocketed: [Int: Pocket]

    static func == (a: ShotRecord, b: ShotRecord) -> Bool {
        a.start == b.start && a.end == b.end && a.preState == b.preState && a.finalState == b.finalState
            && a.cueID == b.cueID && a.firstContact == b.firstContact && a.pocketed == b.pocketed
            && a.rails.map(\.id) == b.rails.map(\.id) && a.rails.map(\.rail) == b.rails.map(\.rail)
    }
}

enum Rail: String, Sendable { case head, foot, left, right }

protocol ShotSegmenting: Sendable {
    /// Feed every tracker update; returns a record when a shot ends.
    /// `strokeRecent`: nil when no cue stick has been seen (no stroke evidence either way); false when the
    /// cue is visible but hasn't stroked — then cue-ball motion (a hand nudge) does not start a shot.
    mutating func update(tracks: [TrackedBall], cueID: Int?, atRest: Bool, at t: Double, strokeRecent: Bool?) -> ShotRecord?
    var inShot: Bool { get }
}

/// SPEC §5.3: a shot starts when the cue ball's speed crosses a threshold for 2 frames (from rest) right after
/// a detected stroke (when the cue stick is visible);
/// it ends when every ball has been at rest for N frames (the tracker's at-rest flag).
struct ShotSegmenter: ShotSegmenting {
    var spec: TableSpec
    var startSpeed = 0.10      // m/s
    var startFrames = 2
    var contactSlack = 0.012   // m beyond 2R
    var railSlack = 0.012      // m beyond R from the nose line
    var pocketZone = 0.07      // m from a pocket centre

    private(set) var inShot = false
    private var fastFrames = 0
    private var lastRest: [Int: Vec2] = [:]
    private var record: ShotRecord?
    private var lastSeen: [Int: (pos: Vec2, t: Double)] = [:]
    private var lastVel: [Int: Vec2] = [:]

    init(spec: TableSpec) { self.spec = spec }

    mutating func update(tracks: [TrackedBall], cueID: Int?, atRest: Bool, at t: Double,
                         strokeRecent: Bool? = nil) -> ShotRecord? {
        let confirmed = tracks.filter(\.confirmed)
        if !inShot {
            if atRest { lastRest = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id, $0.position) }) }
            guard let cueID, let cue = confirmed.first(where: { $0.id == cueID }) else { fastFrames = 0; return nil }
            fastFrames = cue.speed > startSpeed ? fastFrames + 1 : 0
            guard fastFrames >= startFrames, !lastRest.isEmpty, strokeRecent ?? true else { return nil }
            inShot = true
            fastFrames = 0
            record = ShotRecord(start: t, end: t, preState: lastRest, finalState: [:], cueID: cueID, firstContact: nil,
                                rails: [], pocketed: [:])
            lastSeen = [:]; lastVel = [:]
        }
        guard var rec = record else { return nil }
        let R = TableSpec.ballRadius
        let byID = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id, $0) })
        // First contact: an object ball near the cue ball starts moving.
        if rec.firstContact == nil, let cue = byID[rec.cueID] {
            for b in confirmed where b.id != rec.cueID && b.speed > startSpeed {
                let start = rec.preState[b.id] ?? b.position
                if cue.position.distance(to: b.position) < 2 * R + contactSlack + b.speed * 0.05
                    || cue.position.distance(to: start) < 2 * R + contactSlack + 0.03 {
                    rec.firstContact = b.id
                    break
                }
            }
        }
        // Rails: normal velocity reverses near a cushion nose line.
        for b in confirmed {
            if let pv = lastVel[b.id] {
                let p = b.position, v = b.velocity
                func near(_ d: Double) -> Bool { d < R + railSlack + 0.02 }
                var hit: Rail?
                if near(p.x) && pv.x < -0.05 && v.x >= 0 { hit = .head }
                else if near(spec.length - p.x) && pv.x > 0.05 && v.x <= 0 { hit = .foot }
                else if near(p.y) && pv.y < -0.05 && v.y >= 0 { hit = .left }
                else if near(spec.width - p.y) && pv.y > 0.05 && v.y <= 0 { hit = .right }
                if let hit, rec.rails.last.map({ $0.id != b.id || $0.rail != hit }) ?? true { rec.rails.append((b.id, hit)) }
            }
            lastVel[b.id] = b.velocity
            lastSeen[b.id] = (b.position, t)
        }
        // Pocketed: tracked before, gone now, last seen in a capture zone.
        for (id, seen) in lastSeen where byID[id] == nil && rec.pocketed[id] == nil {
            if let p = spec.pockets.first(where: { seen.pos.distance(to: spec.pocketCenter($0)) < pocketZone }) {
                rec.pocketed[id] = p
            }
        }
        record = rec
        guard atRest else { return nil }
        rec.end = t
        rec.finalState = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id, $0.position) })
        inShot = false
        record = nil
        lastRest = rec.finalState
        return rec
    }
}
