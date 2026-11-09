import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// Randomized check of LiveModel's shot lifecycle (aims, D30 looks / asks, relocks) against the shell contract
/// (INTERFACES.md D30 note). The generator draws physical motion, the tracker's (possibly lagging) at-rest bit, the
/// filtered velocity, aim evidence and the segmenter's shot lifecycle INDEPENDENTLY; the oracle keeps its own physical
/// and expected-shot state and never reads the model's flags. After every frame / reset / tap:
///  1. at most one shell aim open; aims never end or cancel without one open;
///  2. no close during a reset, nor unless the current frame is physically quiet (no motion, no aim evidence), the
///     shell has no aim open, and a quiet frame has been seen since the last relock (taps: the last frame, no reset since);
///  3. every close is the next expected entry (a shot in its end order, or a shot lost in flight), of the right kind,
///     carrying that shot's own resolved record, immediately followed by exactly one matching shell call;
///  4. the confirm is never visible, and the standalone badge never shown, during motion or aim evidence;
///  5. at the end (the segmenter model ends every started shot within its 8 s timeout; then quiet frames and answers),
///     every expected entry has closed and no aim is open.
@MainActor
struct ShotLifecycleInvariantTests {
    static let seed: UInt64 = 0xC0FFEE_D31
    static let sequences = 3000
    static let framesPerSequence = 80

    struct RNG { var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    enum Expected { case shot(ShotRecord), lost }

    @MainActor final class Oracle {
        var starts = 0, ends = 0, cancels = 0
        var expected: [Expected] = []
        var closed = 0
        var awaiting: Bool?             // after a seam close: the hook kind still owed (rated?), nil = none owed
        var closeAllowed = false
        var now = 0.0, frameIndex = 0
        var context = ""
        var violations: [String] = []
        var open: Int { starts - ends - cancels }
        /// Reason → (count, first "seq/frame/t").
        static var tally: [String: (Int, String)] = [:]
        func fail(_ s: @autoclosure () -> String) {
            let msg = s()
            if let a = msg.range(of: "["), let b = msg.range(of: "]", range: a.upperBound..<msg.endIndex) {
                let key = String(msg[a.upperBound..<b.lowerBound]).components(separatedBy: ",").first ?? ""
                let first = String(msg[..<msg.range(of: ":")!.lowerBound])
                Oracle.tally[key] = ((Oracle.tally[key]?.0 ?? 0) + 1, Oracle.tally[key]?.1 ?? first)
            }
            if violations.count < 20 { violations.append(msg) }
        }
        func shellClose(rated: Bool, _ seq: Int) {
            if let want = awaiting {
                if want != rated { fail("seq \(seq): shell close kind mismatch") }
            } else { fail("seq \(seq): shell close without a FIFO close") }
            awaiting = nil
            if !closeAllowed || open != 0 { fail("seq \(seq) frame \(frameIndex) t \(String(format: "%.2f", now)): close during motion/aim/reset [\(context)]") }
        }
    }

    func frame(_ t: Double, motion: Bool, atRest: Bool, velocity: Bool, evidence: (addr: Bool, live: Bool),
               started: Bool = false, shot: ShotRecord? = nil, extra: [TrackedBall] = [], occupied: Set<Pocket> = [],
               inView: Set<Pocket> = Set(Pocket.allCases)) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: velocity ? Vec2(0.8, 0) : .zero, kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue] + extra, marks: [1: .cue], atRest: atRest,
                                 aim: nil, detectMs: 0)
        r.motionOnset = motion          // the pipeline's raw signal reports physical motion
        r.shooterAddressing = evidence.addr
        if evidence.live { r.liveAim = LiveAimTrace(cue: .zero, end: Vec2(1, 0), hitIndex: nil, ghost: nil, objectDirection: nil) }
        r.shotStarted = started
        r.shot = shot
        r.ballIDs = [1: .cue, 2: BallID(3)!, 3: BallID(11)!, 4: BallID(5)!]
        r.pocketsOccupied = occupied
        r.pocketsInView = inView
        return r
    }

    @Test func randomSequencesKeepTheShellContract() {
        Oracle.tally = [:]
        var rng = RNG(s: Self.seed)
        var stats = (frames: 0, shots: 0, lost: 0, resets: 0, taps: 0, laggingRest: 0, movingAddressReset: 0)
        var violations: [String] = []
        for seq in 0..<Self.sequences {
            let m = LiveModel(mode: .game)
            let o = Oracle()
            var h = LiveHooks(
                aimStarted: { o.starts += 1; if o.open > 1 { o.fail("seq \(seq): two aims open") } },
                aimEnded: { o.ends += 1; if o.open < 0 { o.fail("seq \(seq): aimEnded with no aim open") } },
                aimCancelled: { o.cancels += 1; if o.open < 0 { o.fail("seq \(seq): aimCancelled with no aim open") } },
                ballsSettled: { o.shellClose(rated: false, seq) },
                settled: { _, _ in o.shellClose(rated: true, seq) })
            h.shellShowsBadge = false     // Live draws its own badge: check it directly
            let game = TargetLegality.startingGame(.barEight)
            h.currentGame = { game }
            m.hooks = h
            m.onCloseForTesting = { id, rec, rated in
                if o.awaiting != nil { o.fail("seq \(seq): previous close never reached the shell") }
                o.awaiting = rated
                guard id == o.closed, id < o.expected.count else {
                    o.fail("seq \(seq): close \(id) but expected \(o.closed) of \(o.expected.count)"); return
                }
                o.closed += 1
                switch (o.expected[id], rec) {
                case (.lost, nil): if rated { o.fail("seq \(seq): lost shot \(id) closed rated") }
                case (.shot(let want), let got?):
                    if !rated { o.fail("seq \(seq): shot \(id) closed unrated") }
                    if got.start != want.start || got.end != want.end || got.cueID != want.cueID || got.firstContact != want.firstContact {
                        o.fail("seq \(seq): shot \(id) closed with another shot's record")
                    }
                    if !Set(got.pocketed.keys).isSubset(of: Set(want.pocketed.keys).union(want.uncertainPockets.keys)) {
                        o.fail("seq \(seq): shot \(id) resolved pockets it never had")
                    }
                    if !got.uncertainPockets.isEmpty { o.fail("seq \(seq): shot \(id) closed with unresolved pockets") }
                default: o.fail("seq \(seq): close \(id) kind does not match its shot")
                }
            }

            var t = 0.0
            var inFlight = false, deadline = 0, sinceStart = 0
            var lastQuiet = true, clearSinceReset = true, resetSinceFrame = false
            func drive(_ r: PerceptionResult, motion: Bool) {
                let evidence = r.shooterAddressing || r.liveAim != nil
                let quietNow = !motion && !evidence
                if quietNow { clearSinceReset = true }
                o.closeAllowed = quietNow && clearSinceReset
                o.now = t; o.frameIndex += 1
                o.context = motion && r.atRest ? "B1: physical motion with atRest=true" :
                    (motion ? "motion" : (evidence ? "aim evidence" : (!clearSinceReset ? "B2: no quiet frame since relock" : "quiet")))
                m.drive(r)
                o.closeAllowed = false
                if o.awaiting != nil { o.fail("seq \(seq): a FIFO close never reached the shell") }
                lastQuiet = quietNow
                resetSinceFrame = false
                if m.showsPocketConfirm && !quietNow { o.fail("seq \(seq) t \(t): confirm visible during motion/aim") }
                if m.badge != nil && (!quietNow || r.shotStarted) { o.fail("seq \(seq) t \(t): badge during motion/aim") }
                if o.open < 0 || o.open > 1 { o.fail("seq \(seq): aim balance \(o.open)") }
                if r.shotStarted { inFlight = true; sinceStart = 0; deadline = 3 + Int(rng.next() % 118) }   // ≤ 8 s
                if r.shot != nil { inFlight = false }
                stats.frames += 1
            }
            func nextFrame(windDown: Bool) {
                t += 1.0 / 15
                if inFlight { sinceStart += 1 }
                // The segmenter model: a started shot ends (balls at rest) by its deadline.
                if inFlight && sinceStart >= deadline {
                    var rec = ShotRecord(start: t - Double(sinceStart) / 15, end: t, preState: [:], finalState: [:], cueID: 1,
                                         firstContact: 2, rails: [], pocketed: [:])
                    if rng.chance(0.5) { rec.pocketed[2] = rng.pick(Pocket.allCases) }
                    if rng.chance(0.3) { rec.pocketed[3] = rng.pick(Pocket.allCases) }
                    if rng.chance(0.5) { rec.uncertainPockets[4] = rng.pick(Pocket.allCases) }
                    o.expected.append(.shot(rec)); stats.shots += 1
                    let ev = windDown ? (false, false) : (rng.chance(0.3), false)
                    let inView = rng.chance(0.4) ? Set(Pocket.allCases).subtracting([rng.pick(Pocket.allCases)]) : Set(Pocket.allCases)
                    drive(frame(t, motion: false, atRest: true, velocity: false, evidence: ev, shot: rec, inView: inView), motion: false)
                    return
                }
                if windDown {
                    drive(frame(t, motion: false, atRest: true, velocity: false, evidence: (false, false)), motion: false)
                    return
                }
                // Independent physical state.
                let motion = rng.chance(inFlight ? 0.5 : 0.2)
                let atRest = motion ? rng.chance(0.3) : rng.chance(0.85)            // the rest bit lags both ways
                if motion && atRest { stats.laggingRest += 1 }
                let velocity = motion && rng.chance(0.5)                             // filtered velocity may be zeroed
                let evidence = (rng.chance(0.2), rng.chance(0.08))
                let started = !inFlight && motion && rng.chance(0.25)
                var extra: [TrackedBall] = []
                var occupied: Set<Pocket> = []
                var ids: [Int: BallID] = [:]
                if rng.chance(0.08) {                                                 // a ball reappears / sits in the jaws
                    let id = [2, 3, 4][Int(rng.next() % 3)]
                    extra.append(TrackedBall(id: 10 + id, position: Vec2(0.4, 0.4), velocity: .zero, kind: .solid,
                                             tentativeNumber: id == 2 ? 3 : (id == 3 ? 11 : 5), confirmed: true))
                    ids[10 + id] = [2: BallID(3)!, 3: BallID(11)!, 4: BallID(5)!][id]
                    if rng.chance(0.5) { occupied = [rng.pick(Pocket.allCases)] }
                }
                var r = frame(t, motion: motion, atRest: atRest, velocity: velocity, evidence: evidence, started: started,
                              extra: extra, occupied: occupied)
                r.ballIDs.merge(ids) { a, _ in a }
                drive(r, motion: motion)
            }

            for _ in 0..<Self.framesPerSequence {
                let u = rng.unit()
                if u < 0.04 {
                    stats.resets += 1
                    if inFlight && !lastQuiet { stats.movingAddressReset += 1 }
                    // A relock turns every not-yet-closed shot into a lost one, then adds the shot in flight.
                    for i in o.closed..<o.expected.count { o.expected[i] = .lost }
                    if inFlight { o.expected.append(.lost); stats.lost += 1 }
                    o.closeAllowed = false                                             // never close inside a reset
                    o.context = lastQuiet ? "B2: inside a reset" : "B2: inside a reset, last frame had motion/aim evidence"
                    m.perceptionReset()
                    if o.awaiting != nil { o.fail("seq \(seq): a FIFO close never reached the shell") }
                    if o.open != 0 { o.fail("seq \(seq): reset left an aim open") }
                    if m.showsPocketConfirm { o.fail("seq \(seq): confirm visible after reset") }
                    inFlight = false; clearSinceReset = false; resetSinceFrame = true
                } else if u < 0.10 {
                    stats.taps += 1
                    o.closeAllowed = lastQuiet && clearSinceReset && !resetSinceFrame
                    o.context = "tap (last frame quiet \(lastQuiet), reset since \(resetSinceFrame))"
                    m.answerPocket(dropped: rng.chance(0.5))
                    o.closeAllowed = false
                    if o.awaiting != nil { o.fail("seq \(seq): a FIFO close never reached the shell") }
                    if m.showsPocketConfirm && !(lastQuiet && !resetSinceFrame) { o.fail("seq \(seq): confirm visible after a tap in motion/aim") }
                } else {
                    nextFrame(windDown: false)
                }
            }
            // Wind down: the segmenter model ends any started shot (≤ 8 s); quiet frames; answer every question.
            var n = 0, quietAfterEnd = 0
            while (inFlight || quietAfterEnd < 30) && n < 300 {
                nextFrame(windDown: true); n += 1
                quietAfterEnd = inFlight ? 0 : quietAfterEnd + 1
            }
            var guardN = 0
            while m.pocketConfirm != nil && guardN < 50 {
                o.closeAllowed = lastQuiet && clearSinceReset
                m.answerPocket(dropped: rng.chance(0.5))
                o.closeAllowed = false
                nextFrame(windDown: true); guardN += 1
            }
            if o.open != 0 { o.fail("seq \(seq): an aim is still open at the end") }
            if o.closed != o.expected.count { o.fail("seq \(seq): \(o.expected.count - o.closed) shot(s) never closed; \(m.lifecycleDebugDescription)") }
            if m.shotsCreatedForTesting != o.expected.count {
                o.fail("seq \(seq): model created \(m.shotsCreatedForTesting) entries, oracle expected \(o.expected.count)")
            }
            violations += o.violations
        }
        print("[invariants] seed \(String(Self.seed, radix: 16)) sequences \(Self.sequences) frames \(stats.frames) shots \(stats.shots) lost \(stats.lost) resets \(stats.resets) taps \(stats.taps) lagging-rest-onsets \(stats.laggingRest) in-flight-resets-during-motion-or-aim \(stats.movingAddressReset)")
        for (k, v) in Oracle.tally.sorted(by: { $0.key < $1.key }) { print("[invariants] violation \(k): \(v.0)× first at \(v.1)") }
        #expect(violations.isEmpty, "\(violations.prefix(10))")
    }
}
