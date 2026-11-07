import Foundation
import Geometry
import Observation

/// UI state for the live screen (AR on device, replay in the simulator).
@MainActor @Observable
final class LiveModel {
    var cornersPlaced = 0
    var calibrated = false
    var planeFound = false
    var trackingOK = true
    var tableSize: TableSize?
    var ballCount = 0
    var atRest = false
    var hasAim = false
    // Debug HUD (dev toggle only, D9).
    var fps = 0.0
    var detectMs = 0.0
    var depthConfidence: Double?
    var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var formatLabel = ""

    var undo: () -> Void = {}
    var recalibrate: () -> Void = {}

    private var frameTimes: [Double] = []

    func noteResult(_ r: PerceptionResult?) {
        let now = Date().timeIntervalSinceReferenceDate
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        fps = Double(frameTimes.count)
        guard let r else { ballCount = 0; atRest = false; hasAim = false; return }
        ballCount = r.tracks.filter(\.confirmed).count
        atRest = r.atRest
        hasAim = r.aim != nil
        detectMs = detectMs * 0.8 + r.detectMs * 0.2
    }
}
