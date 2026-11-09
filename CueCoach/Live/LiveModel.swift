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

    // MARK: Shot lifecycle (D30 + relocks): one FIFO, one state machine
    //
    // Every shot that ends gets an entry, in shot order. An entry is
    //   .looking  - its own post-settle look is running (only the newest entry can be looking);
    //   .decided  - verdicts known; it may still be asking (an uncertain pocket not seen either way);
    //   .lost     - dropped by a relock: it closes unrated.
    // Entries close strictly from the front, one close per shot (`settled` rated, or `ballsSettled` unrated), and only
    // while the table is quiet: nobody aiming and nothing moving. A later shotStarted, or any motion, freezes a look
    // that hasn't finished (unseen uncertain pockets become questions). Only the front entry may ask; a shot queued
    // behind an unanswered question still had its own look in its own window. Nothing stays stuck except an
    // unanswered question.

    private enum ShotState { case looking, decided, lost }
    private struct ShotEntry {
        var id: Int
        var state: ShotState
        var record: ShotRecord?
        var ids: [Int: BallID] = [:]
        var resolver: UncertainPocketResolver?
        var verdicts: [Int: UncertainPocketResolver.Verdict] = [:]
        var answers: [Int: Bool] = [:]

        var openAsk: Int? {
            verdicts.filter { $0.value == .ask && answers[$0.key] == nil }.keys.sorted().first
        }
    }
    private var shots: [ShotEntry] = []
    private var nextShotID = 0
    private func newID() -> Int { defer { nextShotID += 1 }; return nextShotID }
    private func lostEntry() -> ShotEntry { ShotEntry(id: newID(), state: .lost) }
    /// Test seam (the invariant oracle): every close, in order, with the entry's id and its record (nil = unrated).
    @ObservationIgnored var onCloseForTesting: ((Int, ShotRecord?) -> Void)?
    /// Entries created so far (shots ended + shots lost in flight).
    var shotsCreatedForTesting: Int { nextShotID }

    /// The question Live is waiting on (post-shot only). Rules, badge and turn wait for it.
    private(set) var pocketConfirm: PocketConfirm?
    /// Where to draw it (the pocket on screen), set by the active view; nil = bottom centre.
    var pocketConfirmPoint: CGPoint?
    /// Someone is aiming (aim phase open, a live cue line, or the shooter addressing the cue ball).
    private var aimingNow = false
    /// The last frame showed balls at rest (and some balls at all): the physical-motion gate.
    private var atRestNow = true
    /// Quiet = nobody aiming and nothing moving: the only time anything closes, settles, badges or asks.
    private var quiet: Bool { !aimingNow && atRestNow }
    var showsPocketConfirm: Bool { pocketConfirm != nil && quiet }

    /// Perception was reset (revalidation, recalibration, a new table). An open aim is cancelled first, then every
    /// unclosed shot (and the one in flight) is lost: it closes unrated, in order, once the table is quiet.
    func perceptionReset() {
        if aimEvents.phase == .aiming { hooks.aimCancelled() }
        for i in shots.indices where shots[i].state != .lost { shots[i] = ShotEntry(id: shots[i].id, state: .lost) }
        if aimEvents.phase == .moving { shots.append(lostEntry()) }
        aimEvents = AimEvents()
        aimingNow = false
        pocketConfirm = nil
        pocketConfirmPoint = nil
        drain()
    }

    private func enqueue(_ record: ShotRecord, ids: [Int: BallID]) {
        // Every pocketed ball with a rule id gets the look (a jaw-stopped "certain" make is overturned by a sighting);
        // only uncertain ones may be asked.
        let uncertain = record.uncertainPockets.filter { ids[$0.key] != nil }
        let certain = record.pocketed.filter { ids[$0.key] != nil && uncertain[$0.key] == nil }
        let all = uncertain.merging(certain) { u, _ in u }
        let resolver = UncertainPocketResolver(candidates: all, balls: ids, certain: Set(certain.keys))
        // A later shot ends any earlier look still running (even one whose launch wasn't seen).
        for i in shots.indices where shots[i].state == .looking {
            shots[i].verdicts = shots[i].resolver?.frozen() ?? [:]
            shots[i].state = .decided
        }
        shots.append(ShotEntry(id: newID(), state: all.isEmpty ? .decided : .looking, record: record, ids: ids, resolver: resolver))
    }

    /// The newest entry's look sees this frame (its own window only), or is frozen by a later shot or motion.
    private func look(_ r: PerceptionResult, freeze: Bool) {
        guard let i = shots.indices.last, shots[i].state == .looking, var res = shots[i].resolver else { return }
        if freeze {
            shots[i].verdicts = res.frozen()
            shots[i].state = .decided
        } else if let v = res.observe(r) {
            shots[i].verdicts = v
            shots[i].state = .decided
        }
        shots[i].resolver = res
    }

    /// Close entries from the front while the table is quiet; the front may instead ask.
    private func drain() {
        pocketConfirm = nil
        while let head = shots.first {
            switch head.state {
            case .looking:
                return
            case .lost:
                guard quiet else { return }
                shots.removeFirst()
                onCloseForTesting?(head.id, nil)
                hooks.ballsSettled()
            case .decided:
                if let tid = head.openAsk {
                    pocketConfirm = PocketConfirm(trackID: tid, pocket: head.resolver!.candidates[tid]!, ball: head.ids[tid])
                    return
                }
                guard quiet else { return }
                shots.removeFirst()
                onCloseForTesting?(head.id, head.record)
                close(head)
            }
        }
    }

    /// The one-tap answer: ✓ the ball dropped, ✗ it didn't. Only ever applies to the front shot; while something
    /// moves or someone aims it is recorded but nothing closes until the table is quiet.
    func answerPocket(dropped: Bool) {
        guard let q = pocketConfirm, let head = shots.first, head.state == .decided, head.openAsk == q.trackID else { return }
        shots[0].answers[q.trackID] = dropped
        drain()
    }

    private func close(_ e: ShotEntry) {
        guard var rec = e.record, let res = e.resolver else { return }
        for (tid, pk) in res.candidates {
            let dropped = e.answers[tid] ?? (e.verdicts[tid] == .pocketed)
            if dropped { rec.pocketed[tid] = pk } else { rec.pocketed[tid] = nil; rec.pocketTimes[tid] = nil }
            rec.uncertainPockets[tid] = nil
        }
        shotSettled(rec, ids: e.ids)
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

    /// Drives the aim lifecycle and the shot FIFO from each perception result (and hides the badge on aim/motion).
    func drive(_ r: PerceptionResult) {
        let moving = r.confirmed.contains { $0.speed > 0.1 }
        let cueCreeping = r.confirmed.contains { r.marks[$0.id] == .cue && $0.speed > 0.04 }
        // Any pre-shot sign hides the text — even when the cue detector misses the aim (Codex r6).
        if r.liveAim != nil || moving || cueCreeping || r.shotStarted || r.shooterAddressing || !r.atRest { hideBadge() }
        if r.liveAim != nil { showAimHint = false }
        // 1. A later shot or any motion ends an unfinished look (this frame belongs to something else).
        look(r, freeze: r.shotStarted || !r.atRest)
        // 2. The shell always sees the aim lifecycle (the shooter addressing the cue ball counts as aiming, D29).
        for e in aimEvents.update(cueVisible: r.liveAim != nil || r.shooterAddressing, atRest: r.atRest, shotStarted: r.shotStarted,
                                  shotEnded: r.shot != nil, at: r.timestamp) {
            switch e {
            case .aimStarted: hooks.aimStarted()
            case .aimEnded: hooks.aimEnded()
            case .aimCancelled: hooks.aimCancelled()
            case .settled: break   // the shot closes through the FIFO
            }
        }
        aimingNow = r.liveAim != nil || r.shooterAddressing || aimEvents.phase != .idle
        atRestNow = r.atRest && !r.confirmed.isEmpty
        // 3. A shot that ended this frame joins the FIFO; its look starts with this frame.
        if let shot = r.shot {
            enqueue(shot, ids: r.ballIDs)
            look(r, freeze: false)
        }
        // 4. Close / ask from the front.
        drain()
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
