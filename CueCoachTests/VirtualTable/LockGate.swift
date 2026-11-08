import Foundation
import Testing
@testable import CueCoach

/// Acceptance gate for the shipped locator (`.app`) over the VirtualTable matrix (lock plan exit gate).
/// - False locks: 0 in every condition, always.
/// - Accurate-lock % and p50 TTL: per condition, starting at the measured baseline and tightened as each plan
///   step lands. Final target on in-scope conditions: ≥ 95 % accurate, p50 TTL < 1.5 s.
enum LockGate {
    struct Floor { var accuratePct: Double; var ttlP50: Double? }

    /// In scope for the capture-side steps (1, 2, 3, 7): the whole table can be seen from the session's path.
    /// Conditions needing Auto steps 4–6 (partial/far/steep fitting, neutral cloth, shadows/occluders) or the
    /// keypoint seed (step 8) are tracked but not gated on accuracy yet — only on false locks.
    static let inScope: Set<String> = [
        "baseline", "felt-blue", "felt-red", "felt-tan", "light-lamp", "light-neon",
        "clutter-secondTable", "clutter-coffeeTable", "clutter-railObjects", "dist-1.0m",
        "path-endPan", "hold-portrait", "hold-landscape", "fps-30", "fps-60",
    ]

    /// Ratchet: raise these as steps land (never lower). r5 run (Results/r5-app-and-auto.md: Auto 44fd4ed + tablekp + pocket evidence), measured − 10 pts
    /// for timing jitter (the busy flag uses measured CPU), p50 TTL + 0.4 s.
    static let floors: [String: Floor] = [
        "baseline": Floor(accuratePct: 85, ttlP50: 1.7),
        "felt-blue": Floor(accuratePct: 85, ttlP50: 1.7),
        "felt-red": Floor(accuratePct: 70, ttlP50: 1.7),
        "felt-tan": Floor(accuratePct: 45, ttlP50: 1.7),
        "light-lamp": Floor(accuratePct: 35, ttlP50: 1.5),
        "light-neon": Floor(accuratePct: 80, ttlP50: 1.8),
        "clutter-secondTable": Floor(accuratePct: 85, ttlP50: 1.7),
        "clutter-coffeeTable": Floor(accuratePct: 85, ttlP50: 1.6),
        "clutter-railObjects": Floor(accuratePct: 80, ttlP50: 1.6),
        "dist-1.0m": Floor(accuratePct: 80, ttlP50: 1.8),
        "path-endPan": Floor(accuratePct: 80, ttlP50: 1.6),
        "hold-portrait": Floor(accuratePct: 85, ttlP50: 1.7),
        "hold-landscape": Floor(accuratePct: 85, ttlP50: 1.7),
        "fps-30": Floor(accuratePct: 85, ttlP50: 1.7),
        "fps-60": Floor(accuratePct: 80, ttlP50: 1.7),
    ]
    static let defaultFloor = Floor(accuratePct: 0, ttlP50: nil)

    static func check(_ results: [VTRunResult]) {
        guard ProcessInfo.processInfo.environment["VQA_GATE"] != "0" else { return }
        let app = results.filter { $0.locator == .app }
        guard !app.isEmpty else { return }
        for (cond, runs) in Dictionary(grouping: app, by: \.condition) {
            // A lock at the wrong size preset is false too, even under the 20 cm corner cut-off (Codex autocal-r4).
            let falseLocks = runs.filter { $0.falseLock || ($0.locked && $0.sizeOK == false) }.count
            #expect(falseLocks == 0, "\(cond): \(falseLocks) false lock(s) (pose or size) — must be 0")
            guard inScope.contains(cond) else { continue }
            let floor = floors[cond] ?? defaultFloor
            let acc = Double(runs.filter(\.accurate).count) / Double(runs.count) * 100
            #expect(acc >= floor.accuratePct, "\(cond): accurate lock \(Int(acc)) % < floor \(Int(floor.accuratePct)) %")
            if let maxTTL = floor.ttlP50 {
                let ttl = runs.filter(\.accurate).compactMap(\.ttlStart).sorted()
                let p50 = ttl.isEmpty ? .infinity : ttl[ttl.count / 2]
                #expect(p50 <= maxTTL, "\(cond): p50 TTL \(p50) s > \(maxTTL) s")
            }
        }
    }
}
