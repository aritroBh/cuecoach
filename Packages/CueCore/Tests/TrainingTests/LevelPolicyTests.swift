import Foundation
import Testing
@testable import Training

@Suite("LevelPolicy — rolling window with hysteresis (SPEC §10)")
struct LevelPolicyTests {
    let policy = try! LevelPolicy(window: 10, promoteAt: 0.8, demoteAt: 0.4)

    @Test func defaultPolicyIsValidAndHasHysteresis() {
        let p = LevelPolicy.standard
        #expect(p.demoteAt < p.promoteAt)
        #expect(p.window >= 8)
    }
    @Test func rejectsBadConfigurations() {
        #expect(throws: LevelPolicyError.windowTooSmall) { try LevelPolicy(window: 0, promoteAt: 0.8, demoteAt: 0.4) }
        #expect(throws: LevelPolicyError.noHysteresis) { try LevelPolicy(window: 10, promoteAt: 0.5, demoteAt: 0.5) }
        #expect(throws: LevelPolicyError.noHysteresis) { try LevelPolicy(window: 10, promoteAt: 0.4, demoteAt: 0.6) }
        #expect(throws: LevelPolicyError.thresholdOutOfRange) { try LevelPolicy(window: 10, promoteAt: 1.2, demoteAt: 0.4) }
        #expect(throws: LevelPolicyError.thresholdOutOfRange) { try LevelPolicy(window: 10, promoteAt: 0.8, demoteAt: -0.1) }
        #expect(throws: LevelPolicyError.thresholdOutOfRange) { try LevelPolicy(window: 10, promoteAt: .nan, demoteAt: 0.1) }
    }
    @Test func newPlayerStartsAtLevel1() {
        #expect(LevelProgress().level == .full)
    }
    @Test func noDecisionBeforeWindowFills() {
        var p = LevelProgress()
        for _ in 0..<9 { #expect(policy.record(success: true, into: &p) == nil) }
        #expect(p.level == .full)
        #expect(policy.record(success: true, into: &p) == .promoted(to: .objectLineOnly))
        #expect(p.level == .objectLineOnly)
    }
    @Test func promotesAtExactlyThreshold() {
        var p = LevelProgress()
        let seq = [true, true, false, true, true, true, false, true, true, true] // 8/10
        var last: LevelChange?
        for s in seq { last = policy.record(success: s, into: &p) }
        #expect(last == .promoted(to: .objectLineOnly))
    }
    @Test func justBelowThresholdHolds() {
        var p = LevelProgress()
        let seq = [true, false, false, true, true, true, false, true, true, true] // 7/10
        for s in seq { #expect(policy.record(success: s, into: &p) == nil) }
        #expect(p.level == .full)
    }
    @Test func windowResetsAfterChange_noImmediateBounce() {
        var p = LevelProgress()
        for _ in 0..<10 { _ = policy.record(success: true, into: &p) }
        #expect(p.level == .objectLineOnly)
        #expect(p.recent.isEmpty)
        // Nine misses at the new level: still no decision (window refilling).
        for _ in 0..<9 { #expect(policy.record(success: false, into: &p) == nil) }
        #expect(policy.record(success: false, into: &p) == .demoted(to: .full))
    }
    @Test func demotesAtOrBelowDemoteThreshold() {
        var p = LevelProgress(level: .ghostOnly)
        let seq = [true, false, false, true, false, true, false, false, true, false] // 4/10
        var last: LevelChange?
        for s in seq { last = policy.record(success: s, into: &p) }
        #expect(last == .demoted(to: .objectLineOnly))
    }
    @Test func hysteresisBandHoldsLevelIndefinitely() {
        var p = LevelProgress(level: .objectLineOnly)
        // 6/10 forever: inside (0.4, 0.8) band.
        for i in 0..<500 { #expect(policy.record(success: i % 5 < 3, into: &p) == nil) }
        #expect(p.level == .objectLineOnly)
    }
    @Test func rollingWindowDropsOldAttempts() {
        var p = LevelProgress(level: .objectLineOnly)
        for _ in 0..<4 { _ = policy.record(success: false, into: &p) }
        for _ in 0..<6 { _ = policy.record(success: true, into: &p) }  // 6/10 band
        #expect(p.level == .objectLineOnly)
        #expect(policy.record(success: true, into: &p) == nil)           // 7/10
        #expect(policy.record(success: true, into: &p) == .promoted(to: .ghostOnly)) // 8/10
        #expect(p.recent.count == 0)
    }
    @Test func capsAtLevel4AndFloorsAtLevel1() {
        var top = LevelProgress(level: .none)
        for _ in 0..<50 { #expect(policy.record(success: true, into: &top) == nil) }
        #expect(top.level == .none)
        #expect(top.recent.count == 10)
        var bottom = LevelProgress()
        for _ in 0..<50 { #expect(policy.record(success: false, into: &bottom) == nil) }
        #expect(bottom.level == .full)
    }
    @Test func recentNeverExceedsWindow() {
        var p = LevelProgress(level: .objectLineOnly)
        for i in 0..<1000 { _ = policy.record(success: i % 7 < 4, into: &p); #expect(p.recent.count <= 10) }
    }
    @Test func successRateIsNilUntilAnyAttempt() {
        var p = LevelProgress()
        #expect(p.successRate == nil)
        _ = policy.record(success: true, into: &p)
        _ = policy.record(success: false, into: &p)
        #expect(p.successRate == 0.5)
    }
    @Test func perfectPlayerClimbsAllLevelsInThreeWindows() {
        var p = LevelProgress()
        var changes: [LevelChange] = []
        for _ in 0..<30 { if let c = policy.record(success: true, into: &p) { changes.append(c) } }
        #expect(changes == [.promoted(to: .objectLineOnly), .promoted(to: .ghostOnly), .promoted(to: .none)])
    }
    @Test func progressIsCodable() throws {
        var p = LevelProgress(level: .ghostOnly)
        _ = policy.record(success: true, into: &p)
        let back = try JSONDecoder().decode(LevelProgress.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
    @Test func trainingProgressKeepsLevelsPerDrill() {
        var t = TrainingProgress()
        for _ in 0..<10 { _ = t.record(drill: .long, success: true, policy: policy) }
        #expect(t.level(for: .long) == .objectLineOnly)
        #expect(t.level(for: .banks) == .full)
        let back = try! JSONDecoder().decode(TrainingProgress.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}
