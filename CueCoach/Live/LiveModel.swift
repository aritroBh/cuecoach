import CoreGraphics
import Foundation
import Geometry
import Observation
import UIKit
import Rules
import Engine

/// UI state for the live screen (AR on device, replay in the simulator).
@MainActor @Observable
final class LiveModel {
    let editor = CalibrationEditor()
    let mode: LiveMode
    var visibility: OverlayVisibility { OverlayVisibility.of(mode) }
    /// Why the table isn't locked yet (glyph + dev HUD).
    var lockFailure: LockFailure?
    /// World corners drags snap to (the locator's best current guess).
    var snapTargets: [SIMD3<Double>] = []
    var snappedHandle: Int?
    /// Loupe while dragging a corner.
    var loupeImage: UIImage?
    var loupeCenter: CGPoint?
    /// Post-shot rating badge (game mode, standalone only — the app shell draws its own), auto-dismissed and
    /// hidden the moment the next aim starts or any ball moves (no text while aiming).
    var badge: BadgeStyle?
    private var badgeToken = 0
    /// App-shell lifecycle hooks (LiveSession).
    var hooks = LiveHooks()
    private var aimEvents = AimEvents()
    /// Rules state for ratings and ring legality (bar-8 open table until the shell supplies a game).
    let engine: RulesEngine
    private(set) var game: GameState
    /// Legal targets after the latest shot (the view pushes this to the perception pipeline).
    var legalTargets: Set<BallID> { engine.legalTargets(game) }
    var legalChanged: (Set<BallID>) -> Void = { _ in }
    /// Post-lock "what next": pulse the cue-ball glyph until the first aim.
    var showAimHint = false
    var lastRating: DecisionRating?

    init(mode: LiveMode = .training(level: 3)) {
        self.mode = mode
        let (e, g) = TargetLegality.defaultGame()
        engine = e; game = g
    }

    func showBadge(_ style: BadgeStyle) {
        guard visibility.ratingBadge, !hooks.shellShowsBadge else { return }
        badge = style
        badgeToken += 1
        let token = badgeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            if self?.badgeToken == token { self?.badge = nil }
        }
    }

    /// Perception was reset (revalidation, recalibration, a new table): no shot can settle any more, so an open
    /// aim or shot is closed for the shell (its menu would otherwise stay locked).
    func perceptionReset() {
        if aimEvents.phase != .idle { hooks.aimCancelled() }
        aimEvents = AimEvents()
    }

    func hideBadge() { if badge != nil { badge = nil; badgeToken += 1 } }

    /// Ring legality before the first shot: the shell's active game if injected, else the local default.
    func initialLegalTargets() -> Set<BallID> {
        if let (e, g) = hooks.currentGame() { return e.legalTargets(g) }
        return engine.legalTargets(game)
    }

    /// A shot ended: rate it through the Rules engine against the shell's game (or the local default), advance the
    /// local copy, tell the shell. The shell owns the real game state; it applies its own result.
    func shotSettled(_ record: ShotRecord, ids: [Int: BallID]) {
        let (eng, state) = hooks.currentGame() ?? (engine, game)
        let (rating, result) = RuleRating.rate(record, ids: ids, engine: eng, game: state,
                                               pocketTimes: record.pocketTimes.isEmpty ? nil : record.pocketTimes)
        game = result.nextState
        lastRating = rating
        hooks.gameAdvanced(result.nextState)
        legalChanged(eng.legalTargets(result.nextState))
        if mode == .game {
            hooks.settled(rating, result.turnPasses)
            showBadge(BadgeStyle.of(rating))
        } else {
            hooks.ballsSettled()
        }
    }

    /// Drives the aim lifecycle from each perception result (and hides the badge on aim/motion).
    func drive(_ r: PerceptionResult) {
        let moving = r.confirmed.contains { $0.speed > 0.1 }
        let cueCreeping = r.confirmed.contains { r.marks[$0.id] == .cue && $0.speed > 0.04 }
        // Any pre-shot sign hides the text — even when the cue detector misses the aim (Codex r6).
        if r.liveAim != nil || moving || cueCreeping || r.shotStarted || r.shooterAddressing { hideBadge() }
        if r.liveAim != nil { showAimHint = false }
        // The shooter addressing the cue ball counts as aiming even when the stick is missed (Codex capture-r8).
        for e in aimEvents.update(cueVisible: r.liveAim != nil || r.shooterAddressing, atRest: r.atRest, shotStarted: r.shotStarted,
                                  shotEnded: r.shot != nil, at: r.timestamp) {
            switch e {
            case .aimStarted: hooks.aimStarted()
            case .aimEnded: hooks.aimEnded()
            case .aimCancelled: hooks.aimCancelled()
            case .settled: break   // reported by shotSettled with the rating
            }
        }
        if let shot = r.shot { shotSettled(shot, ids: r.ballIDs) }
    }

    var calibrated = false
    var planeFound = false
    var trackingOK = true
    var bumped = false
    var relocking = false
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
    var convertMs = 0.0
    var totalMs = 0.0
    var depthBalls = 0
    var depthConfidence: Double?
    var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var formatLabel = ""
    /// D12 sanity check: observed / expected ball radius (1.0 = the table scale matches 57.15 mm balls).
    var ballScale: Double?

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
                          trackingOK: trackingOK, bumped: bumped, relocking: relocking)
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
        drive(r)
        detectMs = detectMs * 0.8 + r.detectMs * 0.2
        if let s = r.ballScale { ballScale = s }
        totalMs = totalMs * 0.8 + r.totalMs * 0.2
        depthBalls = r.depthBalls
    }

    func clearCalibration() {
        editor.reset()
        ghostConfidence = 0
        manualCorrection = false
        lockFailure = nil
        snapTargets = []
        loupeImage = nil
        loupeCenter = nil
        relocking = false
        tapMode = false
        showTapFallback = false
        calibrated = false
        tableSize = nil
        handles = []
        noteResult(nil)
    }
}
