import Foundation
import Geometry
import Observation
import simd

/// Corner editing shared by AR and replay: auto-proposal, taps, drags, confirm with outlier feedback.
@MainActor @Observable
final class CalibrationEditor {
    private(set) var corners: [SIMD3<Double>] = []
    /// Corner the validator says doesn't fit (red pulse); nil when fine.
    private(set) var outlier: Int?
    private(set) var fromProposal = false
    /// Bumped on every change so 3D markers rebuild.
    private(set) var revision = 0

    var isComplete: Bool { corners.count == 4 }

    func setProposal(_ c: [SIMD3<Double>]) {
        guard c.count == 4 else { return }
        corners = c; outlier = nil; fromProposal = true; revision += 1
    }

    @discardableResult
    func add(_ w: SIMD3<Double>) -> Bool {
        if let o = outlier {               // re-tap replaces only the bad corner
            corners[o] = w; outlier = nil; revision += 1; return true
        }
        guard corners.count < 4 else { return false }
        corners.append(w); revision += 1
        return true
    }

    func move(_ i: Int, to w: SIMD3<Double>) {
        guard corners.indices.contains(i) else { return }
        corners[i] = w
        if outlier == i { outlier = nil }
        revision += 1
    }

    func undo() {
        guard !corners.isEmpty else { return }
        corners.removeLast(); outlier = nil; fromProposal = false; revision += 1
    }

    func reset() { corners = []; outlier = nil; fromProposal = false; revision += 1 }

    /// The plane the corners live on (mean height, gravity-aligned).
    var plane: Plane3? {
        guard !corners.isEmpty else { return nil }
        let y = corners.map(\.y).reduce(0, +) / Double(corners.count)
        return Plane3(point: SIMD3(corners[0].x, y, corners[0].z), normal: SIMD3(0, 1, 0))
    }

    /// Validates; on failure keeps every corner and flags the one to fix.
    func confirm(viewer: SIMD3<Double>?, size: TableSize? = nil) -> TableFitter.Fit? {
        guard isComplete else { return nil }
        let y = corners.map(\.y).reduce(0, +) / 4
        let flat = corners.map { SIMD3($0.x, y, $0.z) }
        switch CornerValidator.check(flat, viewer: viewer, size: size) {
        case .ok(let fit)?: outlier = nil; return fit
        case .outlier(let i, _)?: outlier = i; revision += 1; return nil
        case nil: return nil
        }
    }

    /// Corners in perimeter order (for drawing the outline as it's built).
    var perimeter: [SIMD3<Double>] {
        guard corners.count >= 3 else { return corners }
        let c = corners.reduce(SIMD3<Double>(), +) / Double(corners.count)
        return corners.sorted { atan2($0.z - c.z, $0.x - c.x) < atan2($1.z - c.z, $1.x - c.x) }
    }
}
