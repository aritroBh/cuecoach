import Foundation
import Testing
@testable import Training

/// Regression tests for the cross-vendor (Codex) review findings, round 2.
@Suite("Training review fixes (round 2)")
struct ReviewFixRound2Tests {
    // MARK: codex-1 — decoding a detector validates that every axis has a config

    @Test func detectorDecodingRejectsConfigsMissingAnAxis() throws {
        let full = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BiasDetector(configs: BiasDetector.Config.calibrated))) as! [String: Any]
        // Dictionaries keyed by a non-String enum encode as [key, value, key, value, ...].
        let pairs = try #require(full["configs"] as? [Any])
        #expect(pairs.count == BiasAxis.allCases.count * 2)
        var partial = full
        partial["configs"] = Array(pairs.dropFirst(2))       // drop one axis
        let data = try JSONSerialization.data(withJSONObject: partial)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BiasDetector.self, from: data) }
    }
    @Test func detectorDecodingStillAcceptsCompleteConfigs() throws {
        var d = BiasDetector(configs: BiasDetector.Config.calibrated)
        for _ in 0..<12 { d.observe(.cut, error: 1) }
        let back = try JSONDecoder().decode(BiasDetector.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    // MARK: codex-4 — hysteresis gap must exceed the comparison epsilon

    @Test func levelPolicyRejectsGapNarrowerThanEpsilon() {
        #expect(throws: LevelPolicyError.noHysteresis) {
            try LevelPolicy(window: 2, promoteAt: 0.5000000005, demoteAt: 0.5)
        }
        let json = #"{"window":2,"promoteAt":0.5000000005,"demoteAt":0.5}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LevelPolicy.self, from: Data(json.utf8)) }
    }
    @Test func rateOnDemoteThresholdNeverPromotes() throws {
        // Narrowest gap the policy accepts: 1 success in 2 sits on demoteAt and must not promote.
        let p = try LevelPolicy(window: 2, promoteAt: 0.5 + 3 * LevelPolicy.epsilon, demoteAt: 0.5)
        var prog = LevelProgress(level: .objectLineOnly)
        _ = p.record(success: true, into: &prog)
        #expect(p.record(success: false, into: &prog) == .demoted(to: .full))
    }

    // MARK: codex-5 — Training depends on Geometry only (docs/INTERFACES.md)

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func packageTrainingTargetDependsOnGeometryOnly() throws {
        let pkg = try String(contentsOf: Self.root.appending(path: "Package.swift"), encoding: .utf8)
        let line = try #require(pkg.split(separator: "\n").first { $0.contains(".target(name: \"Training\"") })
        #expect(line.contains("dependencies: [\"Geometry\"])"), "\(line)")
    }
    @Test func trainingSourcesImportOnlyFoundationAndGeometry() throws {
        let dir = Self.root.appending(path: "Sources/Training")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for f in files {
            for line in try String(contentsOf: f, encoding: .utf8).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("import ") || t.contains(" import ") else { continue }
                let module = t.split(separator: " ").last.map(String.init) ?? ""
                #expect(["Foundation", "Geometry"].contains(module), "\(f.lastPathComponent): \(t)")
            }
        }
    }
}
