import CoreGraphics
import Foundation
import Training
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
    /// The drill being trained (Line 3 is position play only, D24); nil in a game or standalone.
    var drill: DrillID?
    var visibility: OverlayVisibility { OverlayVisibility.of(mode, drill: drill) }
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

    init(mode: LiveMode = .training(level: AssistLevel.full.rawValue)) {
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
        // D30: a held shot can't be looked at or asked about against the new table: drop it, closed unrated for
        // the shell (like a lost shot), so its result can never apply to a later shot. The open aim or moving shot
        // is closed too (GPT-5.6 final re-review): an aim is cancelled first, so the shell re-gates its menu, then
        // each dropped held shot closes; while balls move, every close waits until they are at rest.
        let held = pending.count
        if held > 0 {
            pending = []
            pocketConfirm = nil
            pocketConfirmPoint = nil
            aimingNow = false
        }
        switch aimEvents.phase {
        case .aiming:
            hooks.aimCancelled()
            for _ in 0..<held { hooks.ballsSettled() }
        case .moving:
            lostShots += held + 1   // balls are moving: keep the shell gated until they are at rest again
        case .idle:
            for _ in 0..<held { hooks.ballsSettled() }
        }
        aimEvents = AimEvents()
    }

    /// Shots lost to a perception reset (held ones and the one in flight): each closes unrated once the balls are
    /// seen at rest.
    private var lostShots = 0

    // MARK: D30 "look, then ask"

    /// The question Live is waiting on (post-shot only; hidden while anyone aims). Rules, badge and turn wait.
    private(set) var pocketConfirm: PocketConfirm?
    /// Where to draw it (the pocket on screen), set by the active view; nil = bottom centre.
    var pocketConfirmPoint: CGPoint?
    private var aimingNow = false
    var showsPocketConfirm: Bool { pocketConfirm != nil && !aimingNow }

    private struct PendingShot {
        var record: ShotRecord
        var ids: [Int: BallID]
        var resolver: UncertainPocketResolver
        var verdicts: [Int: UncertainPocketResolver.Verdict]?
        var answers: [Int: Bool] = [:]
    }
    /// Settled shots in order; the first is being resolved. A shot without uncertain pockets passes straight through.
    private var pending: [PendingShot] = []

    private func enqueue(_ record: ShotRecord, ids: [Int: BallID]) {
        // Every pocketed ball with a rule id gets the look (a jaw-stopped "certain" make is overturned by a sighting);
        // only uncertain ones may be asked.
        let uncertain = record.uncertainPockets.filter { ids[$0.key] != nil }
        let certain = record.pocketed.filter { ids[$0.key] != nil && uncertain[$0.key] == nil }
        let all = uncertain.merging(certain) { u, _ in u }
        pending.append(PendingShot(record: record, ids: ids,
                                   resolver: UncertainPocketResolver(candidates: all, balls: ids, certain: Set(certain.keys))))
    }

    private func advancePending(_ r: PerceptionResult?) {
        while var p = pending.first, pocketConfirm == nil {
            if p.resolver.candidates.isEmpty || p.verdicts != nil {
                if let ask = nextAsk(p) { pocketConfirm = ask; return }
                // Never settle (rules, badge, turn) while anyone aims: the result lands once the aim is over.
                guard !aimingNow else { return }
                finish(p)
                continue
            }
            guard let r, let v = p.resolver.observe(r) else { pending[0] = p; return }
            p.verdicts = v
            pending[0] = p
        }
    }

    private func nextAsk(_ p: PendingShot) -> PocketConfirm? {
        guard let v = p.verdicts else { return nil }
        let open = v.filter { $0.value == .ask && p.answers[$0.key] == nil }.keys.sorted()
        return open.first.map { PocketConfirm(trackID: $0, pocket: p.resolver.candidates[$0]!, ball: p.ids[$0]) }
    }

    /// The one-tap answer: ✓ the ball dropped, ✗ it didn't.
    func answerPocket(dropped: Bool) {
        guard let q = pocketConfirm, !pending.isEmpty else { return }
        pending[0].answers[q.trackID] = dropped
        pocketConfirm = nextAsk(pending[0])
        if pocketConfirm == nil { advancePending(nil) }   // settles now unless someone is aiming
    }

    private func finish(_ p: PendingShot) {
        pending.removeFirst()
        var rec = p.record
        for (tid, pk) in p.resolver.candidates {
            let dropped = p.answers[tid] ?? (p.verdicts?[tid] == .pocketed)
            if dropped { rec.pocketed[tid] = pk } else { rec.pocketed[tid] = nil; rec.pocketTimes[tid] = nil }
            rec.uncertainPockets[tid] = nil
        }
        shotSettled(rec, ids: p.ids)
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
        // Shots lost to a relock: ignore frames while their balls are still rolling (no aim open since the relock);
        // once at rest, keep processing the frame (it may already carry the next aim) and close them below, outside
        // any aim and before any later shot's result (GPT-5.6 re-review of 8ede140).
        if lostShots > 0, !r.atRest, aimEvents.phase == .idle { return }
        // The shooter addressing the cue ball counts as aiming even when the stick is missed (Codex capture-r8).
        // The shell always sees the aim lifecycle, held shot or not (its badge silencing and menu gating depend on
        // it); a held shot's settle is delivered later, only while nobody aims (GPT-5.3 re-review K2).
        for e in aimEvents.update(cueVisible: r.liveAim != nil || r.shooterAddressing, atRest: r.atRest, shotStarted: r.shotStarted,
                                  shotEnded: r.shot != nil, at: r.timestamp) {
            switch e {
            case .aimStarted: hooks.aimStarted()
            case .aimEnded: hooks.aimEnded()
            case .aimCancelled: hooks.aimCancelled()
            case .settled: break   // reported by shotSettled with the rating
            }
        }
        aimingNow = r.liveAim != nil || r.shooterAddressing || aimEvents.phase != .idle
        if lostShots > 0, !aimingNow, r.atRest, !r.confirmed.isEmpty {
            let n = lostShots
            lostShots = 0
            for _ in 0..<n { hooks.ballsSettled() }
        }
        if let shot = r.shot { enqueue(shot, ids: r.ballIDs) }
        advancePending(r)
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
