import Foundation
import Testing
@testable import CueCoach

struct UXRound2Tests {
    @Test func liveAimAtAnIllegalBallIsRed() {
        let marks: [Int: TargetMark] = [1: .cue, 2: .legal, 3: .illegal]
        #expect(LiveAimStyle.of(hitTrackID: 3, marks: marks, merged: false) == .illegal)
        #expect(LiveAimStyle.of(hitTrackID: 3, marks: marks, merged: true) == .illegal)   // red wins over green
        #expect(LiveAimStyle.of(hitTrackID: 2, marks: marks, merged: false) == .neutral)
        #expect(LiveAimStyle.of(hitTrackID: 2, marks: marks, merged: true) == .merged)
        #expect(LiveAimStyle.of(hitTrackID: nil, marks: marks, merged: false) == .neutral)
    }

    @Test func noisyConvergenceGivesAtMostOneHaptic() {
        var latch = ConvergenceLatch()
        var rng = SplitMix(seed: 8)
        var haptics = 0
        for i in 0..<300 {   // 10 s at 30 Hz hovering around 0.8 ± 0.06
            if latch.update(0.8 + rng.gauss() * 0.06, at: Double(i) / 30) { haptics += 1 }
        }
        #expect(haptics <= 1, "got \(haptics)")
    }

    @Test func latchEntersAndExitsWithHysteresis() {
        var l = ConvergenceLatch()
        let a = l.update(0.9, at: 0)
        let b = l.update(0.75, at: 0.1)        // between thresholds: stays merged, no haptic
        #expect(a && !b && l.merged)
        for i in 0..<6 { _ = l.update(0.4, at: 0.13 + Double(i) * 0.02) }
        #expect(!l.merged)
        for i in 0..<5 { _ = l.update(0.95, at: 0.25 + Double(i) * 0.03) }   // straight back: no second buzz
        #expect(l.merged)
        for i in 0..<10 { _ = l.update(0.3, at: 1 + Double(i) * 0.03) }      // clearly off the line
        #expect(!l.merged)
        var buzzed = false
        for i in 0..<10 { if l.update(0.98, at: 2.6 + Double(i) * 0.03) { buzzed = true } }   // re-armed after 1 s
        #expect(buzzed)
    }

    @Test func illegalWarningFiresOnceOnEntry() {
        var w = EntryLatch()
        var fired = 0
        // Flickering illegal aim for 2 s (detection drops every 3rd frame) → one warning.
        for i in 0..<60 { if w.update(i % 3 != 0, at: Double(i) / 30) { fired += 1 } }
        #expect(fired == 1)
        // Off for a while, then back on → warns again (a new entry).
        for i in 60..<90 { if w.update(false, at: Double(i) / 30) { fired += 1 } }
        if w.update(true, at: 3.1) { fired += 1 }
        #expect(fired == 2)
    }

    @Test func ringsUseShapeAndCalmPulses() {
        let illegal = RingStyle.of(.illegal, turnAge: 5, time: 0.3)
        #expect(illegal.shape == .dashed)
        #expect(RingStyle.of(.legal, turnAge: 5, time: 0).shape == .solid)
        // Legal: one pulse at turn start, faint afterwards.
        let peak = RingStyle.of(.legal, turnAge: 0.6, time: 0)
        let later = RingStyle.of(.legal, turnAge: 3, time: 0)
        #expect(peak.alpha > later.alpha && later.alpha < 0.4)
        #expect(RingStyle.of(.legal, turnAge: 3, time: 0) == RingStyle.of(.legal, turnAge: 9, time: 7))   // no repeat
        // Illegal breathes slowly; targeted pulses harder.
        let alphas = stride(from: 0.0, to: 2, by: 0.1).map { RingStyle.of(.illegal, turnAge: 5, time: $0).alpha }
        #expect(alphas.max()! - alphas.min()! > 0.2)
        #expect(RingStyle.of(.illegal, turnAge: 5, time: 0.2, targeted: true).alpha >= RingStyle.of(.illegal, turnAge: 5, time: 0.2).alpha)
    }
}
