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
    /// What the overlay may draw right now (read live by the views): the aiming set, or (D1) the after-shot set once
    /// the last shot has settled and no aim is open. A new aim (or a relock) hides it again.
    var visibility: OverlayVisibility {
        OverlayVisibility.of(mode, drill: drill, afterShot: shotSettledNoAim && aimEvents.phase == .idle)
    }
    /// D1: a shot closed and no aim has started since.
    private(set) var shotSettledNoAim = false
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
    /// The mounted view binds its pipeline's `setLegal` here (once per mount): settled shots push through
    /// `legalChanged`, and the shell gets the same sink for between-shots changes. Only a mounted model calls this, so a
    /// throwaway `LiveScreen.init` (SwiftUI keeps the first `@State` model) never takes the shell's sink.
    func bindLegal(_ push: @escaping (Set<BallID>) -> Void) {
        legalChanged = push
        hooks.legalSink { [weak self] in self?.legalChanged($0) }
    }
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
    //   .lost     - dropped by a relock. The shot in flight at the relock carries a D31 best guess (the table's last
    //               known rule-id state): once quiet, its look runs and it closes rated on the guessed record; with no
    //               pre-shot state (or the look cut short by a new shot) it closes unrated. Entries that had already
    //               ended (held D30 shots) close unrated, as before.
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
        /// D31: the shot in flight at a relock.
        var guess: LostShotGuess?

        var openAsk: Int? {
            verdicts.filter { $0.value == .ask && answers[$0.key] == nil }.keys.sorted().first
        }
    }
    private var shots: [ShotEntry] = []
    /// A shot has ended but not closed yet (asking, looking, lost, or waiting for a quiet table).
    var hasOpenShot: Bool { !shots.isEmpty }
    /// D37: the player confirmed "End game"; Live stays up until the open shot closes.
    private(set) var isFinishing = false
    private var onFinished: (@MainActor () -> Void)?
    /// D37: only a game asks before ✕ closes Live; Training closes at once.
    var asksBeforeClosing: Bool { mode == .game }
    /// D37: end once every open shot has closed (through the normal FIFO, the pocket question still answerable).
    /// `done` runs exactly once; a second request while finishing is ignored.
    /// D42: a second request while finishing forces the end at once.
    func requestEnd(_ done: @escaping @MainActor () -> Void) {
        guard !isFinishing else { return forceEnd() }
        guard hasOpenShot else { return done() }
        isFinishing = true
        onFinished = done
    }
    /// D42: stop waiting for a quiet table (second ✕, or the screen's ~5 s give-up). Every open shot closes now, in
    /// order, with what is known: a running look freezes and an unasked/unanswered pocket takes the look's verdict.
    func forceEnd() {
        guard isFinishing, let done = onFinished else { return }
        onFinished = nil
        pocketConfirm = nil
        while !shots.isEmpty {
            var head = shots.removeFirst()
            switch head.state {
            case .looking:
                head.verdicts = head.resolver?.frozen() ?? [:]
                close(head)
            case .decided:
                close(head)
            case .lost:
                if let (rec, ids) = head.guess?.record() {
                    onCloseForTesting?(head.id, rec, true)
                    shotSettled(rec, ids: ids, guessed: true)
                } else {
                    onCloseForTesting?(head.id, nil, false)
                    shotSettledNoAim = true
                    hooks.ballsSettled()
                }
            }
        }
        done()
    }
    private var nextShotID = 0
    private func newID() -> Int { defer { nextShotID += 1 }; return nextShotID }
    private func lostEntry() -> ShotEntry {
        // D31: guess from the last quiet pre-shot table (nothing known = no guess, unrated close).
        let spec = TableSpec(size: tableSize ?? .sevenFoot)
        let guess = tableBefore.flatMap { $0.isEmpty ? nil : LostShotGuess(before: $0, lastSeen: lastSeenAt, start: lastFrameAt ?? 0, spec: spec) }
        return ShotEntry(id: newID(), state: .lost, guess: guess)
    }
    /// D31: rule id → position on the last quiet, pre-shot frame (nil = nothing known since the last relock).
    private var tableBefore: [BallID: Vec2]?
    /// D31: rule id → where it was last measured (the pocket guess), since the last relock.
    private var lastSeenAt: [BallID: Vec2] = [:]
    private var lastFrameAt: Double?
    /// Test seam (the invariant oracle): every close, in order, right before its shell/rules effect: the entry's id,
    /// the resolved record that is applied (nil = unrated), and whether it is rated.
    @ObservationIgnored var onCloseForTesting: ((Int, ShotRecord?, Bool) -> Void)?
    /// Entries created so far (shots ended + shots lost in flight).
    var shotsCreatedForTesting: Int { nextShotID }
    /// FIFO and gate state for test diagnostics.
    var lifecycleDebugDescription: String {
        "fifo \(shots.map { "\($0.id):\($0.state)\($0.openAsk.map { "?\($0)" } ?? "")" }) phase \(aimEvents.phase) evidence \(aimEvidence) moving \(movingNow) clear \(clearSinceReset) confirm \(pocketConfirm != nil)"
    }

    /// The question Live is waiting on (post-shot only). Rules, badge and turn wait for it.
    private(set) var pocketConfirm: PocketConfirm?
    /// Where to draw it (the pocket on screen), set by the active view; nil = bottom centre.
    var pocketConfirmPoint: CGPoint?
    /// Physical aim evidence on the last frame (a live cue line, or the shooter addressing the cue ball). It is what
    /// the camera saw, so a relock does not clear it.
    private var aimEvidence = false
    /// The ONE physical-motion signal (last frame): the tracker not at rest, raw motion onset (which leads the
    /// debounced at-rest), or any ball moving; for closing, a frame with no balls seen counts as not quiet too.
    private var movingNow = false
    /// Last time each confirmed track was measured (partial-dropout continuity).
    private var lastMeasuredAt: [Int: Double] = [:]
    static let dropoutWindow = 0.3
    /// After a relock nothing drains until a fresh frame proves no aim and no motion.
    private var clearSinceReset = true
    /// Quiet = no aim (phase or evidence) and nothing moving: the only time anything closes, settles, badges or asks.
    private var quiet: Bool { aimEvents.phase == .idle && !aimEvidence && !movingNow && clearSinceReset }
    var showsPocketConfirm: Bool { pocketConfirm != nil && quiet }

    /// Perception was reset (revalidation, recalibration, a new table). An open aim is cancelled first, then every
    /// unclosed shot (and the one in flight) is lost: it closes unrated, in order, once the table is quiet.
    func perceptionReset() {
        if aimEvents.phase == .aiming { hooks.aimCancelled() }
        for i in shots.indices where shots[i].state != .lost { shots[i] = ShotEntry(id: shots[i].id, state: .lost) }
        // A guess still looking starts its look over on the new tracker (no shot since).
        for i in shots.indices { shots[i].guess?.restart() }
        if aimEvents.phase == .moving { shots.append(lostEntry()) }
        tableBefore = nil
        lastSeenAt = [:]
        aimEvents = AimEvents()
        shotSettledNoAim = false
        pocketConfirm = nil
        pocketConfirmPoint = nil
        // The aim evidence and motion seen last stay; nothing closes until a post-relock frame shows the table quiet
        // (GPT-5.6: a shooter addressing while the segmenter held the last shot open must not see shell text).
        clearSinceReset = false
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
                if let g = head.guess, !g.done { return }
                shots.removeFirst()
                if let (rec, ids) = head.guess?.record() {
                    onCloseForTesting?(head.id, rec, true)
                    shotSettled(rec, ids: ids, guessed: true)
                } else {
                    onCloseForTesting?(head.id, nil, false)
                    shotSettledNoAim = true
                    hooks.ballsSettled()
                }
            case .decided:
                if let tid = head.openAsk {
                    pocketConfirm = PocketConfirm(trackID: tid, pocket: head.resolver!.candidates[tid]!, ball: head.ids[tid])
                    return
                }
                guard quiet else { return }
                shots.removeFirst()
                close(head)
            }
        }
        if let done = onFinished { onFinished = nil; done() }
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
        onCloseForTesting?(e.id, rec, true)
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
    /// `guessed`: a D31 lost shot's best-guess record (the shell's review flags it).
    func shotSettled(_ record: ShotRecord, ids: [Int: BallID], guessed: Bool = false) {
        let (eng, state) = hooks.currentGame() ?? (engine, game)
        let pocketTimes = record.pocketTimes.isEmpty ? nil : record.pocketTimes
        let (rating, result) = RuleRating.rate(record, ids: ids, engine: eng, game: state, pocketTimes: pocketTimes)
        game = result.nextState
        lastRating = rating
        shotSettledNoAim = true
        hooks.gameAdvanced(result.nextState)
        legalChanged(eng.legalTargets(result.nextState))
        if mode == .game {
            hooks.settledShot(SettledShot(rating: rating, turnPasses: result.turnPasses,
                                          pocketed: RuleRating.outcome(record, ids: ids).pocketed,
                                          fouls: result.fouls, isGuess: guessed))
            showBadge(BadgeStyle.of(rating))
        } else {
            hooks.ballsSettled()
        }
    }

    /// Drives the aim lifecycle and the shot FIFO from each perception result (and hides the badge on aim/motion).
    func drive(_ r: PerceptionResult) {
        let ballMoving = r.confirmed.contains { $0.speed > 0.1 }
        let cueCreeping = r.confirmed.contains { r.marks[$0.id] == .cue && $0.speed > 0.04 }
        // Partial dropout: a confirmed ball measured within the last `dropoutWindow` s but not this frame may be the
        // one that just launched; motion can't be excluded (GPT-5.6 review of 71b0253).
        var dropout = false
        var seenNow: [Int: Double] = [:]
        for b in r.confirmed {
            if b.measured { seenNow[b.id] = r.timestamp }
            else if let last = lastMeasuredAt[b.id] {
                seenNow[b.id] = last
                if r.timestamp - last <= Self.dropoutWindow { dropout = true }
            }
        }
        lastMeasuredAt = seenNow
        // The one physical-motion signal: not at rest, raw onset (leads the debounced at-rest), a ball moving, or a
        // just-seen ball unmeasured.
        let moving = !r.atRest || r.motionOnset || ballMoving || cueCreeping || dropout
        // Aim evidence: a live cue line, the shooter addressing the cue ball (D29), or a stick near it (D33, no stroke needed).
        let evidence = r.liveAim != nil || r.shooterAddressing || r.stickNearCue
        // Any pre-shot sign hides the text — even when the cue detector misses the aim (Codex r6).
        if evidence || moving || r.shotStarted { hideBadge() }
        if r.liveAim != nil { showAimHint = false }
        // 1. A later shot or any motion ends an unfinished look (this frame belongs to something else).
        look(r, freeze: r.shotStarted || moving)
        // 2. The shell always sees the aim lifecycle (the shooter addressing the cue ball counts as aiming, D29).
        //    Addressing while the segmenter still holds the last shot open (.moving) opens no shell aim: the shell is
        //    still gated on that shot; the aim opens on the shot-end frame or the first frame after a relock.
        for e in aimEvents.update(cueVisible: evidence, atRest: r.atRest && !moving, shotStarted: r.shotStarted,
                                  shotEnded: r.shot != nil, at: r.timestamp) {
            switch e {
            case .aimStarted: shotSettledNoAim = false; hooks.aimStarted()
            case .aimEnded: hooks.aimEnded()
            case .aimCancelled: hooks.aimCancelled()
            case .settled: break   // the shot closes through the FIFO
            }
        }
        aimEvidence = evidence
        // Nothing seen to judge by (e.g. right after a relock) is not quiet either.
        movingNow = moving || r.confirmed.isEmpty
        if !clearSinceReset, !evidence, !movingNow { clearSinceReset = true }
        // D31: the table's rule-id state before a shot, and where each ball was last measured.
        lastFrameAt = r.timestamp
        for b in r.confirmed where b.measured { if let id = r.ballIDs[b.id] { lastSeenAt[id] = b.position } }
        if aimEvents.phase != .moving && !movingNow && !r.shotStarted && r.shot == nil {
            var t: [BallID: Vec2] = [:]
            for b in r.confirmed { if let id = r.ballIDs[b.id] { t[id] = b.position } }
            tableBefore = t
        }
        // D31: a lost shot's look sees every still frame with a measured ball, aim or not (Grok 4.7 review: the next
        // shooter may already be down on the cue ball; closing still waits for quiet). A new shot before it finished
        // cuts it short (no guess); a finished look is kept.
        if let i = shots.firstIndex(where: { $0.guess.map { !$0.done } ?? false }) {
            if r.shotStarted || r.shot != nil { shots[i].guess?.freeze() }
            else if aimEvents.phase != .moving && !movingNow && r.confirmed.contains(where: \.measured) { shots[i].guess?.observe(r) }
        }
        // 3. A shot that ended this frame joins the FIFO; its look starts with this frame.
        if let shot = r.shot {
            enqueue(shot, ids: r.ballIDs)
            // A shot-end frame that already shows the next motion is not this shot's look: freeze at once.
            look(r, freeze: moving || r.shotStarted)
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
    /// Smoothed `CoreMLBallInference.shared` predict and letterbox times (plan 003).
    var modelMs = 0.0
    var letterboxMs = 0.0
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
        if let m = CoreMLBallInference.shared {
            modelMs = modelMs * 0.8 + m.lastInferenceMs * 0.2
            letterboxMs = letterboxMs * 0.8 + m.lastLetterboxMs * 0.2
        }
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
