import CoreGraphics
import Foundation
import Geometry
import Observation

/// UI state for the live screen (AR on device, replay in the simulator).
@MainActor @Observable
final class LiveModel {
    let editor = CalibrationEditor()

    var calibrated = false
    var planeFound = false
    var trackingOK = true
    var bumped = false
    var tableSize: TableSize?
    var ballCount = 0
    var atRest = false
    var aim: AimSuggestion?
    var proposing = false
    /// Ghost-table confidence while the locator converges (0…1).
    var ghostConfidence = 0.0
    /// User dragged a corner: locator updates stop overriding; ✓ confirms.
    var manualCorrection = false
    /// Last resort: tap-4 offered after the locator has had a fair chance.
    var showTapFallback = false
    var tapMode = false
    /// Screen positions of the corner handles (view points), refreshed every render frame.
    var handles: [CGPoint?] = []
    /// Incremented when a tap can't be used yet (no plane): the coaching glyph shakes.
    var notReadyTick = 0

    // Debug HUD (dev toggle only, D9).
    var fps = 0.0
    var detectMs = 0.0
    var depthConfidence: Double?
    var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var formatLabel = ""

    // Actions wired by the active view (AR or replay).
    var undo: () -> Void = {}
    var autoPropose: () -> Void = {}
    var recalibrate: () -> Void = {}
    var confirm: () -> Void = {}
    /// Drag handle `i` so its centre sits at the given view point.
    var dragHandle: (Int, CGPoint) -> Void = { _, _ in }
    var startTapMode: () -> Void = {}

    var status: LiveStatus {
        LiveStatus.derive(planeFound: planeFound, corners: editor.corners.count, calibrated: calibrated,
                          trackingOK: trackingOK, bumped: bumped)
    }

    private var frameTimes: [Double] = []

    func noteResult(_ r: PerceptionResult?) {
        let now = Date().timeIntervalSinceReferenceDate
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        fps = Double(frameTimes.count)
        guard let r else { ballCount = 0; atRest = false; aim = nil; return }
        ballCount = r.confirmed.count
        atRest = r.atRest
        aim = r.aim
        detectMs = detectMs * 0.8 + r.detectMs * 0.2
    }

    func clearCalibration() {
        editor.reset()
        ghostConfidence = 0
        manualCorrection = false
        tapMode = false
        showTapFallback = false
        calibrated = false
        tableSize = nil
        handles = []
        noteResult(nil)
    }
}
