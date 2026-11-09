import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// Randomized check of the shot-lifecycle state machine (LiveModel: aims, D30 looks / asks, relocks) against the
/// shell contract (INTERFACES.md, D30 note), with a hook-event log as the oracle. After every frame:
///  1. aims started − (ended + cancelled) is 0 or 1 (the shell's aim is open or not);
///  2. no close (rated or unrated) while the shell's aim is open, on a moving frame, or while someone aims;
///  3. every close is the next entry in shot order (ids 0, 1, 2, …), each exactly once, and a rated close carries the
///     record of its own shot;
///  4. the confirm is never visible during an aim or motion;
///  5. at the end, after quiet frames and answering every question, every entry is closed (nothing stuck).
@MainActor
struct ShotLifecycleInvariantTests {
    static let seed: UInt64 = 0xC0FFEE_D30
    static let sequences = 3000
    static let framesPerSequence = 70

    struct RNG { var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    @MainActor final class Oracle {
        var starts = 0, ends = 0, cancels = 0
        var closedIDs: [Int] = []
        var closedStarts: [Double] = []
        var generatedStarts: Set<Double> = []
        var violations: [String] = []
        /// Whether a close is allowed right now (set by the driver around each call).
        var closeAllowed = true
        var open: Int { starts - ends - cancels }
        func check(_ cond: Bool, _ what: @autoclosure () -> String) { if !cond && violations.count < 20 { violations.append(what()) } }
    }

    func frame(_ t: Double, rest: Bool, addressing: Bool = false, liveAim: Bool = false, started: Bool = false,
               shot: ShotRecord? = nil, extra: [TrackedBall] = [], occupied: Set<Pocket> = [],
               inView: Set<Pocket> = Set(Pocket.allCases)) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: rest ? .zero : Vec2(0.8, 0), kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue] + extra, marks: [1: .cue], atRest: rest, aim: nil,
                                 detectMs: 0)
        r.shooterAddressing = addressing
        if liveAim { r.liveAim = LiveAimTrace(cue: .zero, end: Vec2(1, 0), hitIndex: nil, ghost: nil, objectDirection: nil) }
        r.shotStarted = started
        r.shot = shot
        r.ballIDs = [1: .cue, 2: BallID(3)!, 3: BallID(11)!, 4: BallID(5)!]
        r.pocketsOccupied = occupied
        r.pocketsInView = inView
        return r
    }

    @Test func randomSequencesKeepTheShellContract() {
        var rng = RNG(s: Self.seed)
        var totalFrames = 0, totalShots = 0, totalResets = 0, totalAsks = 0
        var violations: [String] = []
        for seq in 0..<Self.sequences {
            let m = LiveModel(mode: .game)
            let o = Oracle()
            var h = LiveHooks(
                aimStarted: { o.starts += 1; o.check(o.open <= 1, "seq \(seq): two aims open") },
                aimEnded: { o.ends += 1; o.check(o.open >= 0, "seq \(seq): aimEnded without an open aim") },
                aimCancelled: { o.cancels += 1; o.check(o.open >= 0, "seq \(seq): aimCancelled without an open aim") },
                ballsSettled: { o.check(o.closeAllowed && o.open == 0, "seq \(seq): unrated close during aim/motion") },
                settled: { _, _ in o.check(o.closeAllowed && o.open == 0, "seq \(seq): rated close during aim/motion") })
            let game = TargetLegality.startingGame(.barEight)
            h.currentGame = { game }
            m.hooks = h
            m.onCloseForTesting = { id, rec in
                o.check(id == o.closedIDs.count, "seq \(seq): close \(id) out of order (expected \(o.closedIDs.count))")
                o.closedIDs.append(id)
                if let rec {
                    o.check(o.generatedStarts.contains(rec.start), "seq \(seq): a close carried a record no shot produced")
                    o.check(!o.closedStarts.contains(rec.start), "seq \(seq): a shot's result applied twice")
                    o.closedStarts.append(rec.start)
                }
            }
            var t = 0.0
            var lastQuiet = true, lastAtRest = true, inFlight = false
            func drive(_ r: PerceptionResult) {
                // A close may happen on this frame only if it is at rest with nobody aiming (shell aim checked live).
                o.closeAllowed = r.atRest && !r.shooterAddressing && r.liveAim == nil
                m.drive(r)
                lastQuiet = r.atRest && !r.shooterAddressing && r.liveAim == nil
                lastAtRest = r.atRest
                if r.shotStarted { inFlight = true }
                if r.shot != nil { inFlight = false }
                o.check(!m.showsPocketConfirm || lastQuiet, "seq \(seq) t \(t): confirm visible during aim/motion")
                o.check(o.open == 0 || o.open == 1, "seq \(seq): aim balance \(o.open)")
                totalFrames += 1
            }
            for _ in 0..<Self.framesPerSequence {
                t += 1.0 / 15
                let u = rng.unit()
                switch u {
                case ..<0.30: drive(frame(t, rest: true))
                case ..<0.45: drive(frame(t, rest: false))
                case ..<0.58: drive(frame(t, rest: true, addressing: true))
                case ..<0.63: drive(frame(t, rest: true, liveAim: true))
                case ..<0.71: drive(frame(t, rest: false, addressing: rng.unit() < 0.5, started: true))
                case ..<0.81:
                    var rec = ShotRecord(start: t, end: t, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
                    if rng.unit() < 0.5 { rec.pocketed[2] = rng.pick(Pocket.allCases) }
                    if rng.unit() < 0.3 { rec.pocketed[3] = rng.pick(Pocket.allCases) }
                    if rng.unit() < 0.5 { rec.uncertainPockets[4] = rng.pick(Pocket.allCases) }
                    o.generatedStarts.insert(t)
                    totalShots += 1
                    let inView = rng.unit() < 0.4 ? Set(Pocket.allCases).subtracting([rng.pick(Pocket.allCases)]) : Set(Pocket.allCases)
                    drive(frame(t, rest: true, addressing: rng.unit() < 0.3, shot: rec, inView: inView))
                case ..<0.88:
                    let id = [2, 3, 4][Int(rng.next() % 3)]
                    let ball = TrackedBall(id: 10 + id, position: Vec2(0.4, 0.4), velocity: .zero, kind: .solid,
                                           tentativeNumber: id == 2 ? 3 : (id == 3 ? 11 : 5), confirmed: true)
                    var r = frame(t, rest: true, extra: [ball], occupied: rng.unit() < 0.5 ? [rng.pick(Pocket.allCases)] : [])
                    r.ballIDs[10 + id] = r.ballIDs[id]
                    drive(r)
                case ..<0.92:
                    totalResets += 1
                    // A reset cancels any open aim first, then may close what it dropped: only rest is required.
                    o.closeAllowed = lastAtRest
                    m.perceptionReset()
                    inFlight = false
                    o.check(o.open == 0, "seq \(seq): reset left the shell's aim open")
                default:
                    if m.pocketConfirm != nil { totalAsks += 1 }
                    o.closeAllowed = lastQuiet
                    m.answerPocket(dropped: rng.unit() < 0.5)
                    o.check(!m.showsPocketConfirm || lastQuiet, "seq \(seq): confirm visible after a tap during aim/motion")
                }
            }
            // Wind down. The real segmenter always ends a shot it started: end one still in flight, then quiet
            // frames, then answer every question; nothing may remain open.
            if inFlight {
                t += 1.0 / 15
                let rec = ShotRecord(start: t, end: t, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
                o.generatedStarts.insert(t)
                drive(frame(t, rest: true, shot: rec))
            }
            for _ in 0..<40 { t += 1.0 / 15; drive(frame(t, rest: true)) }
            var guardN = 0
            while m.pocketConfirm != nil && guardN < 50 {
                o.closeAllowed = true
                m.answerPocket(dropped: rng.unit() < 0.5)
                t += 1.0 / 15; drive(frame(t, rest: true)); guardN += 1
            }
            o.check(o.open == 0, "seq \(seq): an aim is still open at the end")
            o.check(o.closedIDs.count == m.shotsCreatedForTesting,
                    "seq \(seq): \(m.shotsCreatedForTesting - o.closedIDs.count) shot(s) never closed")
            violations += o.violations
            if violations.count >= 20 { break }
        }
        print("[invariants] seed \(String(Self.seed, radix: 16)) sequences \(Self.sequences) frames \(totalFrames) shots \(totalShots) resets \(totalResets) taps-on-asks \(totalAsks)")
        #expect(violations.isEmpty, "\(violations.prefix(10))")
    }
}
