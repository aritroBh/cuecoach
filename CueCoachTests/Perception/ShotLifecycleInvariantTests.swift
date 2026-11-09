import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// Randomized check of LiveModel's shot lifecycle (aims, D30 looks / asks, relocks) against the shell contract
/// (INTERFACES.md D30 note). The generator draws physical motion and, independently, which motion signals report it
/// (raw onset, the tracker's at-rest bit, filtered velocity, a launching ball missed for 1-6 frames, which is motion only
/// within 0.3 s of its last measurement on the oracle's own clock), aim evidence (with sustained aims that flicker for
/// 1-3 frames) and the segmenter's shot lifecycle. Expected quiet is computed after the expected aim update, so a
/// retained aim (the 1 s evidence-loss grace) is never quiet. The oracle keeps its OWN spec models, computed only from what it generated:
///  - the aim state machine: the exact expected aimStarted / aimEnded / aimCancelled hooks per call, in order;
///  - each shot's look (its own window, freezes, sightings, observed-empty frames) → verdicts, and the confirm /
///    answers → the FULL expected resolved ShotRecord, compared with `==`;
///  - the expected FIFO (shots in end order, relock-lost entries).
/// Checked after every call: hooks exactly as expected; no close during a reset, physical motion or aim evidence, or
/// before a quiet frame since the last relock; each close is the next entry, of the right kind (a recorded shot rated
/// via settled, a lost entry unrated via ballsSettled), with exactly its
/// expected resolved record, followed by exactly one shell call; confirm and standalone badge never visible during
/// motion or aim; at the end every entry closed.
@MainActor
struct ShotLifecycleInvariantTests {
    static let seed: UInt64 = 0xC0FFEE_D33
    static let sequences = 3000
    static let framesPerSequence = 80

    struct RNG { var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    nonisolated static let ruleIDs: [Int: BallID] = [1: .cue, 2: BallID(3)!, 3: BallID(11)!, 4: BallID(5)!]

    // MARK: Oracle spec models

    enum Phase { case idle, aiming, moving }
    enum Verdict { case onTable, pocketed, ask }

    struct Look {
        var candidates: [Int: Pocket]
        var certain: Set<Int>
        var start: Double?
        var frames = 0
        var visible: [Int: Int] = [:]
        var seen: Set<Int> = []
        var done = false
        var verdicts: [Int: Verdict] = [:]

        mutating func finish(final: Bool) {
            done = true
            for (tid, _) in candidates {
                if seen.contains(tid) { verdicts[tid] = .onTable }
                else if certain.contains(tid) { verdicts[tid] = .pocketed }
                else if final && frames > 0 && Double(visible[tid] ?? 0) >= 0.8 * Double(frames) { verdicts[tid] = .pocketed }
                else { verdicts[tid] = .ask }
            }
        }
        mutating func observe(_ r: PerceptionResult) {
            if start == nil { start = r.timestamp }
            frames += 1
            let measured = r.tracks.filter { $0.confirmed && $0.measured }
            let usable = !measured.isEmpty
            for (tid, pk) in candidates {
                if usable && r.pocketsInView.contains(pk) { visible[tid, default: 0] += 1 }
                if r.pocketsOccupied.contains(pk) { seen.insert(tid) }
                if measured.contains(where: { $0.id == tid }) { seen.insert(tid) }
                if let b = ShotLifecycleInvariantTests.ruleIDs[tid], measured.contains(where: { r.ballIDs[$0.id] == b }) { seen.insert(tid) }
            }
            if r.timestamp - start! >= 1.0 { finish(final: true) }
        }
        func openAsk(_ answers: [Int: Bool]) -> Int? {
            guard done else { return nil }
            return verdicts.filter { $0.value == .ask && answers[$0.key] == nil }.keys.sorted().first
        }
    }

    struct Entry {
        var record: ShotRecord?        // nil = lost
        var look: Look?
        var answers: [Int: Bool] = [:]
        var expectedResolved: ShotRecord? {
            guard var rec = record, let look else { return nil }
            for (tid, pk) in look.candidates {
                let dropped = answers[tid] ?? (look.verdicts[tid] == .pocketed)
                if dropped { rec.pocketed[tid] = pk } else { rec.pocketed[tid] = nil; rec.pocketTimes[tid] = nil }
                rec.uncertainPockets[tid] = nil
            }
            return rec
        }
    }

    @MainActor final class Oracle {
        // aim spec
        var phase = Phase.idle
        var lostAt: Double?
        var actualAim: [String] = []
        // FIFO spec
        var entries: [Entry] = []
        var closed = 0
        var confirm: (entry: Int, tid: Int)?
        var awaiting: Bool?
        var closeAllowed = false
        var violations: [String] = []
        var context = ""
        static var tally: [String: (Int, String)] = [:]

        func fail(_ key: String, _ s: @autoclosure () -> String) {
            Oracle.tally[key] = ((Oracle.tally[key]?.0 ?? 0) + 1, Oracle.tally[key]?.1 ?? s())
            if violations.count < 20 { violations.append("[\(key)] " + s()) }
        }

        /// The aim contract (INTERFACES D30 note / AimEvents), from generated inputs only.
        func expectAim(evidence: Bool, rest: Bool, started: Bool, ended: Bool, t: Double) -> [String] {
            if ended && phase == .moving {
                phase = .idle; lostAt = nil
                if evidence && rest { phase = .aiming; return ["start"] }
                return []
            }
            if ended && phase == .aiming {
                lostAt = nil
                if evidence { return [] }
                phase = .idle; return ["cancel"]
            }
            if started && phase != .moving {
                let was = phase == .aiming
                phase = .moving; lostAt = nil
                return was ? ["end"] : ["start", "end"]
            }
            switch phase {
            case .idle: if rest && evidence { phase = .aiming; return ["start"] }
            case .aiming:
                if evidence { lostAt = nil }
                else if let l = lostAt { if t - l > 1.0 { phase = .idle; lostAt = nil; return ["cancel"] } }
                else { lostAt = t }
            case .moving: break
            }
            return []
        }

        /// The look spec for a drive: freeze / observe the newest looking entry, then a new shot's entry.
        func lookStep(_ r: PerceptionResult, signal: Bool, beforeEnqueue: Bool) {
            guard let i = entries.indices.last, var look = entries[i].look, !look.done else { return }
            if signal || r.shotStarted { look.finish(final: false) } else { look.observe(r) }
            entries[i].look = look
        }

        func enqueue(_ rec: ShotRecord, ids: [Int: BallID]) {
            for i in entries.indices where entries[i].look.map({ !$0.done }) ?? false { entries[i].look!.finish(final: false) }
            let uncertain = rec.uncertainPockets.filter { ids[$0.key] != nil }
            let certain = rec.pocketed.filter { ids[$0.key] != nil && uncertain[$0.key] == nil }
            var look = Look(candidates: uncertain.merging(certain) { u, _ in u }, certain: Set(certain.keys))
            if look.candidates.isEmpty { look.done = true }
            entries.append(Entry(record: rec, look: look))
        }

        func refreshConfirm() {
            confirm = nil
            guard closed < entries.count, entries[closed].record != nil, let look = entries[closed].look,
                  let tid = look.openAsk(entries[closed].answers) else { return }
            confirm = (closed, tid)
        }
    }

    func frame(_ t: Double, atRest: Bool, onset: Bool, velocity: Bool, cueMeasured: Bool, evidence: (addr: Bool, live: Bool),
               started: Bool = false, shot: ShotRecord? = nil, extra: [TrackedBall] = [], occupied: Set<Pocket> = [],
               inView: Set<Pocket> = Set(Pocket.allCases)) -> PerceptionResult {
        var cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: velocity ? Vec2(0.8, 0) : .zero, kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        cue.measured = cueMeasured
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue] + extra, marks: [1: .cue], atRest: atRest,
                                 aim: nil, detectMs: 0)
        r.motionOnset = onset
        r.shooterAddressing = evidence.addr
        if evidence.live { r.liveAim = LiveAimTrace(cue: .zero, end: Vec2(1, 0), hitIndex: nil, ghost: nil, objectDirection: nil) }
        r.shotStarted = started
        r.shot = shot
        r.ballIDs = Self.ruleIDs
        r.pocketsOccupied = occupied
        r.pocketsInView = inView
        return r
    }

    @Test func randomSequencesKeepTheShellContract() {
        let result = Self.run(seed: Self.seed, sequences: Self.sequences)
        print(result.summary)
        for (k, v) in result.tally.sorted(by: { $0.key < $1.key }) { print("[invariants] violation \(k): \(v.0)× first: \(v.1)") }
        #expect(result.violations.isEmpty, "\(result.violations.prefix(10))")
    }

    static func run(seed: UInt64, sequences: Int) -> (summary: String, violations: [String], tally: [String: (Int, String)]) {
        let me = ShotLifecycleInvariantTests()
        Oracle.tally = [:]
        var rng = RNG(s: seed)
        var st = (frames: 0, shots: 0, lost: 0, resets: 0, taps: 0, answered: 0, onsetOnly: 0, notAtRestOnly: 0,
                  velocityOnly: 0, dropoutOnly: 0, compared: 0, endWithOnset: 0,
                  flicker: 0, grace: 0, runInWindow: 0, runPast: 0)
        var violations: [String] = []
        for seq in 0..<sequences {
            let m = LiveModel(mode: .game)
            let o = Oracle()
            var h = LiveHooks(
                aimStarted: { o.actualAim.append("start") },
                aimEnded: { o.actualAim.append("end") },
                aimCancelled: { o.actualAim.append("cancel") },
                ballsSettled: {
                    if o.awaiting != false { o.fail("shell-close", "seq \(seq): unrated shell close without a matching FIFO close") }
                    o.awaiting = nil
                    if !o.closeAllowed { o.fail("close-gate", "seq \(seq): unrated close during \(o.context)") }
                },
                settled: { _, _ in
                    if o.awaiting != true { o.fail("shell-close", "seq \(seq): rated shell close without a matching FIFO close") }
                    o.awaiting = nil
                    if !o.closeAllowed { o.fail("close-gate", "seq \(seq): rated close during \(o.context)") }
                })
            h.shellShowsBadge = false
            let game = TargetLegality.startingGame(.barEight)
            h.currentGame = { game }
            m.hooks = h
            m.onCloseForTesting = { id, rec, rated in
                if o.awaiting != nil { o.fail("shell-close", "seq \(seq): a FIFO close never reached the shell") }
                o.awaiting = rated
                guard id == o.closed, id < o.entries.count else {
                    o.fail("fifo-order", "seq \(seq): close \(id), expected \(o.closed) of \(o.entries.count)"); return
                }
                let e = o.entries[id]
                o.closed += 1
                switch (e.record, rec) {
                case (nil, nil): if rated { o.fail("close-kind", "seq \(seq): lost entry \(id) closed rated") }
                case (.some, let got?):
                    if !rated { o.fail("close-kind", "seq \(seq): recorded entry \(id) closed unrated") }
                    let want = e.expectedResolved
                    st.compared += 1
                    if got != want { o.fail("resolved-record", "seq \(seq): entry \(id) resolved \(got.pocketed) want \(String(describing: want?.pocketed))") }
                default: o.fail("close-kind", "seq \(seq): close \(id) kind does not match its entry")
                }
            }

            var t = 0.0
            var inFlight = false, deadline = 0, sinceStart = 0
            var lastQuiet = true, clearSinceReset = true, resetSinceFrame = false
            var cueLastMeasuredAt: Double? = nil          // the oracle's own continuity clock (no prior measurement yet)
            var dropLeft = 0, holdAim = 0, gapLeft = 0    // generator: dropout run / sustained aim with flicker

            func checkAim(_ want: [String], _ what: String) {
                if o.actualAim != want { o.fail("aim-hooks", "seq \(seq) t \(String(format: "%.2f", t)) \(what): hooks \(o.actualAim) want \(want)") }
                o.actualAim = []
            }

            func drive(_ r: PerceptionResult, phys: Bool) {
                let evidence = r.shooterAddressing || r.liveAim != nil
                let cueMeasured = r.tracks.first { $0.id == 1 }?.measured ?? true
                // Partial dropout: unmeasured within 0.3 s of the cue's last measurement (the oracle's own clock).
                let dropout = !cueMeasured && (cueLastMeasuredAt.map { r.timestamp - $0 <= 0.3 } ?? false)
                let signal = !r.atRest || r.motionOnset || r.tracks.contains { $0.confirmed && $0.speed > 0.04 } || dropout || phys
                if !evidence && !signal { clearSinceReset = true }
                // spec: look step 1, aim, enqueue + look on the new entry
                o.lookStep(r, signal: signal, beforeEnqueue: true)
                let want = o.expectAim(evidence: evidence, rest: !signal, started: r.shotStarted, ended: r.shot != nil, t: r.timestamp)
                // Quiet AFTER the expected aim update: a retained aim (the 1 s evidence-loss grace) is not quiet.
                let quietNow = o.phase == .idle && !evidence && !signal && clearSinceReset
                if o.phase == .aiming && !evidence && !signal { st.grace += 1 }
                o.closeAllowed = quietNow
                o.context = phys ? (r.atRest ? "physical motion with atRest=true" : "physical motion")
                    : (evidence ? "aim evidence" : (signal ? "a motion signal" : (o.phase != .idle ? "the aim grace (\(o.phase))"
                    : (clearSinceReset ? "quiet" : "no quiet frame since relock"))))
                if let shot = r.shot { o.enqueue(shot, ids: r.ballIDs); o.lookStep(r, signal: signal, beforeEnqueue: false) }
                m.drive(r)
                o.closeAllowed = false
                checkAim(want, "frame")
                if o.awaiting != nil { o.fail("shell-close", "seq \(seq): a FIFO close never reached the shell") }
                o.refreshConfirm()
                lastQuiet = quietNow
                resetSinceFrame = false
                if cueMeasured { cueLastMeasuredAt = r.timestamp }
                if m.showsPocketConfirm && !quietNow { o.fail("confirm-gate", "seq \(seq) t \(t): confirm visible during \(o.context)") }
                if m.badge != nil && (!quietNow || r.shotStarted) { o.fail("badge-gate", "seq \(seq) t \(t): badge during \(o.context)") }
                if r.shotStarted { inFlight = true; sinceStart = 0; deadline = 3 + Int(rng.next() % 118) }   // ≤ 8 s
                if r.shot != nil { inFlight = false }
                st.frames += 1
            }

            func nextFrame(windDown: Bool) {
                t += 1.0 / 15
                if inFlight { sinceStart += 1 }
                if inFlight && sinceStart >= deadline {                       // the segmenter model ends the shot
                    var rec = ShotRecord(start: t - Double(sinceStart) / 15, end: t, preState: [1: Vec2(0.5, 0.5)],
                                         finalState: [1: Vec2(1.2, 0.6)], cueID: 1, firstContact: rng.chance(0.8) ? 2 : nil,
                                         rails: rng.chance(0.5) ? [(id: 1, rail: rng.pick([Rail.head, .foot, .left, .right]))] : [],
                                         pocketed: [:])
                    if rng.chance(0.5) { rec.pocketed[2] = rng.pick(Pocket.allCases); rec.pocketTimes[2] = t - 0.5 }
                    if rng.chance(0.3) { rec.pocketed[3] = rng.pick(Pocket.allCases); rec.pocketTimes[3] = t - 0.4 }
                    if rng.chance(0.5) { rec.uncertainPockets[4] = rng.pick(Pocket.allCases) }
                    if rng.chance(0.1) { rec.missing = [3] }
                    st.shots += 1
                    let ev = windDown ? (false, false) : (rng.chance(0.3), false)
                    let inView = rng.chance(0.4) ? Set(Pocket.allCases).subtracting([rng.pick(Pocket.allCases)]) : Set(Pocket.allCases)
                    // Sometimes the end frame already carries the next motion's raw onset (and a ball in the jaws).
                    let onsetAtEnd = !windDown && rng.chance(0.15)
                    if onsetAtEnd { st.endWithOnset += 1 }
                    drive(me.frame(t, atRest: true, onset: onsetAtEnd, velocity: false, cueMeasured: true, evidence: ev,
                                   shot: rec, occupied: onsetAtEnd && rng.chance(0.5) ? Set(rec.pocketed.values) : [],
                                   inView: inView), phys: onsetAtEnd)
                    return
                }
                if windDown {
                    dropLeft = 0; holdAim = 0; gapLeft = 0
                    drive(me.frame(t, atRest: true, onset: false, velocity: false, cueMeasured: true,
                                             evidence: (false, false)), phys: false)
                    return
                }
                // Aim evidence: random, or a sustained aim (entered while the spec is aiming) with 1-3 frame flickers.
                var evidence = (rng.chance(0.2), rng.chance(0.08))
                if holdAim > 0 {
                    holdAim -= 1
                    if gapLeft > 0 { gapLeft -= 1; evidence = (false, false); st.flicker += 1 }
                    else if rng.chance(0.25) { gapLeft = Int(rng.next() % 3); evidence = (false, false); st.flicker += 1 }
                    else { evidence = (true, rng.chance(0.3)) }
                } else if o.phase == .aiming && rng.chance(0.4) {
                    holdAim = 5 + Int(rng.next() % 16)
                }
                let canDrop = cueLastMeasuredAt.map { t - $0 <= 0.3 } ?? false
                // Physical motion, then which signals report it, drawn independently (with sole-signal cases).
                // A dropout run (1-6 unmeasured frames) is motion only while within 0.3 s of the last measurement.
                var phys: Bool
                var onset = false, notAtRest = false, velocity = false, dropout = false
                if dropLeft > 0 {
                    dropLeft -= 1
                    dropout = true
                    phys = canDrop
                    if phys { st.runInWindow += 1 } else { st.runPast += 1; notAtRest = rng.chance(0.12) }
                } else {
                phys = rng.chance(holdAim > 0 ? 0.05 : (inFlight ? 0.5 : 0.2))
                if phys {
                    if rng.chance(0.4) {
                        switch rng.next() % 4 {
                        case 0: onset = true; st.onsetOnly += 1
                        case 1: notAtRest = true; st.notAtRestOnly += 1
                        case 2: velocity = true; st.velocityOnly += 1
                        default: dropout = canDrop; if !dropout { onset = true }
                            if dropout { st.dropoutOnly += 1; dropLeft = Int(rng.next() % 6) }
                        }
                    } else {
                        repeat {
                            onset = rng.chance(0.5); notAtRest = rng.chance(0.5); velocity = rng.chance(0.4)
                            dropout = canDrop && rng.chance(0.15)
                        } while !(onset || notAtRest || velocity || dropout)
                        if dropout { dropLeft = Int(rng.next() % 6) }
                    }
                } else {
                    notAtRest = rng.chance(0.12)                                   // the rest bit lags after motion
                }
                }
                let started = !inFlight && phys && rng.chance(0.25)
                var extra: [TrackedBall] = []
                var occupied: Set<Pocket> = []
                var ids: [Int: BallID] = [:]
                if rng.chance(0.1) {                                                // a ball reappears / sits in the jaws
                    let id = [2, 3, 4][Int(rng.next() % 3)]
                    extra.append(TrackedBall(id: 10 + id, position: Vec2(0.4, 0.4), velocity: .zero, kind: .solid,
                                             tentativeNumber: id == 2 ? 3 : (id == 3 ? 11 : 5), confirmed: true))
                    ids[10 + id] = ruleIDs[id]
                }
                if rng.chance(0.06) { occupied = [rng.pick(Pocket.allCases)] }
                var r = me.frame(t, atRest: !notAtRest, onset: onset, velocity: velocity, cueMeasured: !dropout,
                                 evidence: evidence, started: started, extra: extra, occupied: occupied,
                                 inView: rng.chance(0.2) ? Set(Pocket.allCases).subtracting([rng.pick(Pocket.allCases)]) : Set(Pocket.allCases))
                r.ballIDs.merge(ids) { a, _ in a }
                drive(r, phys: phys)
            }

            for _ in 0..<framesPerSequenceFor(seq) {
                let u = rng.unit()
                if u < 0.04 {
                    st.resets += 1
                    for i in o.closed..<o.entries.count { o.entries[i] = Entry(record: nil) }
                    if inFlight { o.entries.append(Entry(record: nil)); st.lost += 1 }
                    let want: [String] = o.phase == .aiming ? ["cancel"] : []
                    o.phase = .idle; o.lostAt = nil
                    o.closeAllowed = false
                    o.context = "a reset"
                    m.perceptionReset()
                    checkAim(want, "reset")
                    if o.awaiting != nil { o.fail("shell-close", "seq \(seq): a FIFO close never reached the shell") }
                    if m.showsPocketConfirm { o.fail("confirm-gate", "seq \(seq): confirm visible after reset") }
                    o.confirm = nil
                    inFlight = false; clearSinceReset = false; resetSinceFrame = true
                } else if u < 0.10 {
                    st.taps += 1
                    let dropped = rng.chance(0.5)
                    if let c = o.confirm { o.entries[c.entry].answers[c.tid] = dropped; st.answered += 1 }
                    o.closeAllowed = lastQuiet && clearSinceReset && !resetSinceFrame
                    o.context = "a tap (last frame quiet \(lastQuiet), reset since \(resetSinceFrame))"
                    m.answerPocket(dropped: dropped)
                    o.closeAllowed = false
                    checkAim([], "tap")
                    if o.awaiting != nil { o.fail("shell-close", "seq \(seq): a FIFO close never reached the shell") }
                    o.refreshConfirm()
                    if m.showsPocketConfirm && !(lastQuiet && !resetSinceFrame) { o.fail("confirm-gate", "seq \(seq): confirm visible after a tap") }
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
                let dropped = rng.chance(0.5)
                if let c = o.confirm { o.entries[c.entry].answers[c.tid] = dropped; st.answered += 1 }
                o.closeAllowed = lastQuiet && clearSinceReset
                o.context = "a wind-down tap"
                m.answerPocket(dropped: dropped)
                o.closeAllowed = false
                o.refreshConfirm()
                nextFrame(windDown: true); guardN += 1
            }
            if o.phase != .idle { o.fail("aim-hooks", "seq \(seq): the aim spec ends \(o.phase)") }
            if o.closed != o.entries.count {
                o.fail("stuck", "seq \(seq): \(o.entries.count - o.closed) entr(ies) never closed; \(m.lifecycleDebugDescription)")
            }
            if m.shotsCreatedForTesting != o.entries.count {
                o.fail("fifo-order", "seq \(seq): model created \(m.shotsCreatedForTesting) entries, oracle \(o.entries.count)")
            }
            violations += o.violations
        }
        let summary = "[invariants] seed \(String(seed, radix: 16)) sequences \(sequences) frames \(st.frames) shots \(st.shots) lost \(st.lost) resets \(st.resets) taps \(st.taps) answers \(st.answered) records-compared \(st.compared) sole-signal frames: onset \(st.onsetOnly) not-at-rest \(st.notAtRestOnly) velocity \(st.velocityOnly) dropout \(st.dropoutOnly) shot-end-with-onset \(st.endWithOnset) aim-flicker frames \(st.flicker) grace frames \(st.grace) dropout-run frames in window \(st.runInWindow) past \(st.runPast)"
        return (summary, violations, Oracle.tally)
    }

    static func framesPerSequenceFor(_ seq: Int) -> Int { framesPerSequence }

}
