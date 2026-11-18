import Foundation
import Observation
import SwiftData
import Geometry
import Training

/// Payload delivered by `LiveModel` when a Solo Training shot settles (SPEC §10).
struct SettledTrainingShot: Hashable, Sendable {
    var made: Bool
    var before: [BallID: Vec2] = [:]
    var after: [BallID: Vec2] = [:]
    var targetPocket: Pocket = .footRight
    var tableSize: TableSize = .sevenFoot
    /// Pre-rail initial post-contact departure direction of the target object ball (avoids jaw/cushion rebound sign flips).
    var objectDepartureDir: Vec2? = nil
    /// Pre-contact cue-ball launch speed (m/s).
    var cueLaunchSpeed: Double? = nil
    var objectHitRail: Bool = false
    /// Optional explicit signed errors (used by synthetic replay or unit tests when camera positions are minimal).
    var explicitErrors: [Training.BiasAxis: Double]? = nil
}

/// Orchestrates Solo Training setup ghosts (`SetupMatcher`), rolling auto level-up (`LevelPolicy`),
/// visual tendency detection (`FeedbackCoach` / `BiasDetector`), and `Training.store` persistence.
/// Strictly isolated from `Competitive.store` (SPEC §4, §10).
@MainActor @Observable
final class TrainingSessionController {
    static let setupTolerance: Double = 0.065
    static let fallbackPlayerKey = "cc.training.fallbackPlayerID"

    let drill: DrillID
    let playerID: UUID
    let policy: LevelPolicy
    @ObservationIgnored private let stack: PersistenceStack?
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var tableSize: TableSize
    private(set) var level: AssistLevel
    private(set) var ghostTargets: [Vec2] = []
    private(set) var matchedGhosts: [Bool] = []
    private(set) var positionZoneCenter: Vec2?
    private(set) var attemptCount = 0
    private(set) var activeFeedback: Feedback?
    private(set) var lastLevelChange: Training.LevelChange?

    @ObservationIgnored private var progress: LevelProgress
    @ObservationIgnored private var coach: FeedbackCoach

    var isSetupReady: Bool { SetupMatcher.isReady(matchedGhosts) }

    init(drill: DrillID, initialLevel: AssistLevel, tableSize: TableSize = .sevenFoot,
         playerID: UUID? = nil, stack: PersistenceStack? = nil,
         policy: LevelPolicy = .standard, defaults: UserDefaults = .standard) {
        self.drill = drill
        self.policy = policy
        self.stack = stack
        self.defaults = defaults
        self.playerID = playerID
            ?? stack.flatMap(Self.resolveOwnerID(in:))
            ?? Self.resolveFallbackPlayerID(defaults: defaults)
        self.tableSize = tableSize
        self.level = initialLevel
        self.progress = LevelProgress(level: initialLevel)
        self.coach = FeedbackCoach(drill: drill)
        loadPersistedState()
        refreshSetupTargets()
    }

    static func defaultPocket(for drill: DrillID) -> Pocket {
        switch drill {
        case .sidePocket, .banks: .sideLeft
        case .rail: .footLeft
        default: .footRight
        }
    }

    func updateDetectedBalls(_ detected: [Vec2], tableSize newSize: TableSize? = nil) {
        if let newSize, newSize != tableSize {
            tableSize = newSize
            refreshSetupTargets()
        }
        matchedGhosts = SetupMatcher.match(ghosts: ghostTargets, detected: detected, tolerance: Self.setupTolerance)
    }

    func dismissFeedback() {
        coach.dismiss()
        if let stack {
            let pid = playerID
            let dRaw = drill.rawValue
            let ctx = stack.trainingContext
            if let rows = try? ctx.fetch(FetchDescriptor<BiasRecord>()) {
                for r in rows where r.playerID == pid && r.drill == dRaw && r.resolvedAt == nil { r.resolvedAt = .now }
                try? ctx.save()
            }
        }
        activeFeedback = nil
    }

    func recordAttempt(_ shot: SettledTrainingShot) {
        let now = Date()
        if shot.tableSize != tableSize { tableSize = shot.tableSize }
        let spec = TableSpec(size: tableSize)
        let (storedFeatures, axisErrors) = Self.extractErrors(
            shot: shot, drill: drill, spec: spec, zone: positionZoneCenter)

        let previousLevel = level
        let change = policy.record(success: shot.made, into: &progress)
        lastLevelChange = change
        if progress.level != previousLevel {
            level = progress.level
            defaults.set(level.rawValue, forKey: TrainingPickerModel.levelKey)
        }

        coach.record(axisErrors)
        activeFeedback = coach.current

        persistAttempt(shot: shot, spec: spec, features: storedFeatures,
                       previousLevel: previousLevel, levelChanged: change != nil, at: now)

        attemptCount += 1
        refreshSetupTargets()
    }

    // MARK: - Setup Layouts

    private func refreshSetupTargets() {
        let spec = TableSpec(size: tableSize)
        let setup = Self.targetSetup(for: drill, spec: spec, attemptIndex: attemptCount)
        ghostTargets = setup.ghosts
        positionZoneCenter = setup.positionZone
        matchedGhosts = Array(repeating: false, count: ghostTargets.count)
    }

    static func targetSetup(for drill: DrillID, spec: TableSpec, attemptIndex: Int) -> (ghosts: [Vec2], positionZone: Vec2?) {
        let L = spec.length
        let W = spec.width
        switch drill {
        case .straightIn:
            return ([Vec2(0.28 * L, 0.50 * W), Vec2(0.62 * L, 0.75 * W)], nil)
        case .increasingCuts:
            let step = Double(attemptIndex % 4)
            let yOffset = 0.50 * W + (step - 1.5) * 0.08 * W
            return ([Vec2(0.28 * L, yOffset), Vec2(0.65 * L, 0.72 * W)], nil)
        case .long:
            return ([Vec2(0.16 * L, 0.24 * W), Vec2(0.64 * L, 0.68 * W)], nil)
        case .rail:
            return ([Vec2(0.32 * L, 0.26 * W), Vec2(0.62 * L, 0.09 * W)], nil)
        case .sidePocket:
            return ([Vec2(0.35 * L, 0.68 * W), Vec2(0.50 * L, 0.25 * W)], nil)
        case .positionPlay:
            return ([Vec2(0.30 * L, 0.36 * W), Vec2(0.66 * L, 0.68 * W)], Vec2(0.50 * L, 0.30 * W))
        case .spinControl:
            return ([Vec2(0.30 * L, 0.50 * W), Vec2(0.58 * L, 0.50 * W)], nil)
        case .banks:
            return ([Vec2(0.42 * L, 0.30 * W), Vec2(0.54 * L, 0.74 * W)], nil)
        }
    }

    // MARK: - Error Extraction

    private static func extractErrors(shot: SettledTrainingShot, drill: DrillID, spec: TableSpec,
                                      zone: Vec2?) -> (StoredAttemptFeatures, [Training.BiasAxis: Double]) {
        if let explicit = shot.explicitErrors {
            let stored = StoredAttemptFeatures(
                signedCutError: explicit[.cut] ?? 0,
                signedSpeedError: explicit[.speed] ?? 0,
                cueLandingError: explicit[.cueBallDistance] ?? 0,
                spinIntended: 0,
                spinObserved: explicit[.spin] ?? 0)
            return (stored, explicit)
        }

        var errors: [Training.BiasAxis: Double] = [:]
        var cutErr = 0.0
        var speedErr = 0.0
        var landingErr = 0.0

        let objEntry = shot.before
            .filter({ !$0.key.isCue })
            .sorted(by: { $0.key < $1.key })
            .first
        if let cueBefore = shot.before[.cue], let (_, objBefore) = objEntry {
            let pocketPos = spec.pocketCenter(shot.targetPocket)
            let ghost = AimPlanner.ghostBall(object: objBefore, pocket: pocketPos)
            let idealObjDir = (pocketPos - objBefore).normalized
            let cueToObj = (objBefore - cueBefore).normalized

            // 1. Cut & side miss: use ONLY pre-rail initial object-ball departure (`objectDepartureDir`) so cushion/jaw
            // rebounds into `shot.after` never invert coaching advice.
            if !shot.made, let depDir = shot.objectDepartureDir, depDir.length > 0.5 {
                let normDep = depDir.normalized
                let neededCut = abs(atan2(cueToObj.cross(idealObjDir), cueToObj.dot(idealObjDir)))
                let actualCut = abs(atan2(cueToObj.cross(normDep), cueToObj.dot(normDep)))
                cutErr = actualCut - neededCut
                errors[.cut] = cutErr
                let rightNormal = Vec2(idealObjDir.y, -idealObjDir.x)
                errors[.side] = normDep.dot(rightNormal) * objBefore.distance(to: pocketPos)
            }

            // 2. Cue-ball landing target (`positionPlay` zone, or `spinControl` stop-shot ghost spot):
            // Measure Euclidean miss distance `dist` signed by along-approach projection so off-axis misses on the
            // same-radius circle around `cueBefore` never report zero error. `spin` (`|tip offset| - |intended|`) is
            // never synthesized from signed landing displacement because draw vs follow cannot map monotonically to spin magnitude.
            let cueTarget: Vec2? = if drill == .positionPlay {
                zone
            } else if drill == .spinControl {
                ghost
            } else {
                nil
            }
            if let cueTarget, let cueAfter = shot.after[.cue] {
                let approach = (cueTarget - cueBefore).normalized
                let along = (cueAfter - cueTarget).dot(approach)
                let dist = cueAfter.distance(to: cueTarget)
                landingErr = dist <= TableSpec.ballRadius * 1.5 ? along : (along >= 0 ? dist : -dist)
                errors[.cueBallDistance] = landingErr
            }

            // 3. Speed: prefer pre-contact cue launch speed across all drills; fall back to signed target overshoot
            // in drills with an explicit cue-ball resting target (`positionPlay`, `spinControl`).
            if let launch = shot.cueLaunchSpeed, launch > 0.05 {
                let intended = max(0.85, min(2.5, 0.85 + 0.55 * cueBefore.distance(to: ghost)))
                speedErr = max(-1.0, min(1.5, launch / intended - 1.0))
                errors[.speed] = speedErr
            } else if let cueTarget, shot.after[.cue] != nil {
                speedErr = max(-1.0, min(1.5, landingErr / max(0.35, cueBefore.distance(to: cueTarget))))
                errors[.speed] = speedErr
            }
        }

        let stored = StoredAttemptFeatures(
            signedCutError: cutErr, signedSpeedError: speedErr,
            cueLandingError: landingErr, spinIntended: 0, spinObserved: 0)
        return (stored, errors)
    }

    // MARK: - Training.store Persistence

    private func loadPersistedState() {
        guard let stack else { return }
        let pid = playerID
        let dRaw = drill.rawValue
        let ctx = stack.trainingContext
        if let row = (try? ctx.fetch(FetchDescriptor<DrillProgress>()))?
            .filter({ $0.playerID == pid && $0.drill == dRaw })
            .max(by: { $0.updatedAt < $1.updatedAt }),
           let storedLevel = AssistLevel(rawValue: row.level) {
            // Replay stored recent window into `LevelProgress` at the stored level.
            var restored = LevelProgress(level: storedLevel)
            let noopPolicy = (try? LevelPolicy(window: max(policy.window + 1, row.recentResults.count + 1),
                                               promoteAt: 1.0, demoteAt: 0.0)) ?? policy
            for r in row.recentResults.suffix(max(0, policy.window - 1)) {
                _ = noopPolicy.record(success: r, into: &restored)
            }
            self.progress = restored
            self.level = storedLevel
        }
    }

    private func persistAttempt(shot: SettledTrainingShot, spec: TableSpec, features: StoredAttemptFeatures,
                                previousLevel: AssistLevel, levelChanged: Bool, at now: Date) {
        guard let stack else { return }
        let pid = playerID
        let ctx = stack.trainingContext

        if ((try? ctx.fetch(FetchDescriptor<TrainingProfile>()))?.contains(where: { $0.playerID == pid }) ?? false) == false {
            ctx.insert(TrainingProfile(playerID: pid, createdAt: now, updatedAt: now))
        }

        let dRaw = drill.rawValue
        let progressRow: DrillProgress
        if let existing = (try? ctx.fetch(FetchDescriptor<DrillProgress>()))?
            .filter({ $0.playerID == pid && $0.drill == dRaw })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            progressRow = existing
        } else {
            let created = DrillProgress(playerID: pid, drill: dRaw, level: level.rawValue, updatedAt: now)
            ctx.insert(created)
            progressRow = created
        }

        progressRow.level = level.rawValue
        progressRow.recentResults = progress.recent
        if levelChanged {
            var hist = progressRow.levelHistory
            hist.append(CueCoach.LevelChange(at: now, from: previousLevel.rawValue, to: level.rawValue))
            progressRow.levelHistory = hist
        }

        let setupTable = TableState(spec: spec, balls: shot.before.mapValues { BallState(position: $0) })
        let resultTable = TableState(spec: spec, balls: shot.after.mapValues { BallState(position: $0) })
        let attempt = TrainingAttempt(at: now, setup: setupTable, result: resultTable,
                                      made: shot.made, features: features, updatedAt: now)
        ctx.insert(attempt)
        attempt.progress = progressRow

        // Sync active / resolved `BiasRecord`s in `Training.store`.
        let openBiases = ((try? ctx.fetch(FetchDescriptor<BiasRecord>())) ?? [])
            .filter { $0.playerID == pid && $0.drill == dRaw && $0.resolvedAt == nil }
        if let fb = activeFeedback {
            let sign = fb.bias.direction == .positive ? 1 : -1
            let storedAxis = Self.storedBiasAxis(fb.bias.axis)
            for other in openBiases where other.axis != storedAxis || other.sign != sign {
                other.resolvedAt = now
            }
            if !openBiases.contains(where: { $0.axis == storedAxis && $0.sign == sign }) {
                let detectedCount = coach.detector.activeBiases().first(where: { $0.key == fb.bias })?.attempts ?? 8
                ctx.insert(BiasRecord(playerID: pid, drill: dRaw, axis: storedAxis, sign: sign,
                                      attemptsWindow: detectedCount, detectedAt: now))
            }
        } else {
            for old in openBiases { old.resolvedAt = now }
        }

        try? ctx.save()
    }

    private static func storedBiasAxis(_ a: Training.BiasAxis) -> CueCoach.BiasAxis {
        switch a {
        case .cut: .cut
        case .side: .side
        case .speed: .speed
        case .cueBallDistance: .cueDistance
        case .spin: .spin
        }
    }

    private static func resolveOwnerID(in stack: PersistenceStack) -> UUID? {
        try? stack.competitiveContext.fetch(
            FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner })
        ).first?.id
    }

    private static func resolveFallbackPlayerID(defaults: UserDefaults) -> UUID {
        if let str = defaults.string(forKey: fallbackPlayerKey), let existing = UUID(uuidString: str) {
            return existing
        }
        let created = UUID()
        defaults.set(created.uuidString, forKey: fallbackPlayerKey)
        return created
    }
}
