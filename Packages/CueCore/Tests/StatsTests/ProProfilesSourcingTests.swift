import Foundation
import Testing
@testable import Stats

// SPEC §8 / D27: every non-estimated trait cites a source; break/run-out stay on the Archetypes scale.
@Suite("Pro profile sourcing")
struct ProProfilesSourcingTests {
    private var profiles: [[String: Any]] {
        let obj = try! JSONSerialization.jsonObject(with: Data(proProfilesJSON.utf8)) as! [String: Any]
        return obj["profiles"] as! [[String: Any]]
    }

    @Test func measuredTraitsCiteASource() {
        for p in profiles {
            for (name, raw) in p["traits"] as! [String: [String: Any]] where (raw["estimated"] as? Bool) == false {
                let src = raw["source"] as? String ?? ""
                #expect(src.hasPrefix("https://"), "\(p["name"] ?? "?") \(name) is measured but has no source")
            }
        }
    }

    @Test func breakAndRunOutAreOnTheMeasuredScale() {
        for p in profiles {
            let t = p["traits"] as! [String: [String: Any]]
            for key in ["breakPower", "runOut"] {
                guard let v = t[key]?["value"] as? Double else { continue }
                #expect((0...0.6).contains(v), "\(p["name"] ?? "?") \(key) = \(v) is off the measured scale")
            }
        }
    }

    @Test func tenProsDecode() throws {
        #expect(try ProProfiles.decode(Data(proProfilesJSON.utf8)).count == 10)
    }
}
