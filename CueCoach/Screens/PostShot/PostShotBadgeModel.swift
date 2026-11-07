import Foundation
import Observation
import Engine

/// One engine rating for a settled shot.
struct PostShotRating: Equatable, Sendable {
    var shotID: UUID
    var rating: DecisionRating
    var shooterName: String
    /// 0 = Team A, 1 = Team B.
    var team: Int
}

/// What the live game (engine + mesh) tells the badge. Live game wires a real source later.
enum PostShotSignal: Equatable, Sendable {
    /// Rating ready after all balls are at rest.
    case rated(PostShotRating)
    /// Any phone in the mesh reports aim start.
    case aimStarted
    /// Stroke taken or aim cancelled.
    case aimEnded
    /// Training level 4 hides badges until reveal (D1).
    case badgesLocked(Bool)
}

protocol PostShotSignalSource: Sendable {
    func signals() -> AsyncStream<PostShotSignal>
}

/// Finite in-memory source for previews and tests.
struct InMemoryPostShotSignals: PostShotSignalSource {
    var items: [PostShotSignal]
    init(_ items: [PostShotSignal]) { self.items = items }
    func signals() -> AsyncStream<PostShotSignal> {
        AsyncStream { c in
            for s in items { c.yield(s) }
            c.finish()
        }
    }
}

/// Post-shot badge state machine (pages/screens-b.md §2). Timing lives in the view; the model only
/// decides what is visible, so "silent while aiming" is enforced here and unit-tested.
@MainActor @Observable
public final class PostShotBadgeModel {
    static let holdSeconds: Double = 1.8

    private(set) var current: PostShotRating?
    private(set) var isPinned = false
    private(set) var isAiming = false
    private(set) var badgesLocked: Bool
    /// Bumps every time a new badge appears so a stale hold timer can't dismiss a newer badge.
    private(set) var generation = 0

    @ObservationIgnored private var silenced: Set<UUID> = []
    @ObservationIgnored private let source: (any PostShotSignalSource)?

    init(source: (any PostShotSignalSource)? = nil, badgesLocked: Bool = false) {
        self.source = source
        self.badgesLocked = badgesLocked
    }

    /// Consumes the signal source until it finishes (call from `.task`).
    func run() async {
        guard let source else { return }
        for await s in source.signals() { receive(s) }
    }

    func receive(_ signal: PostShotSignal) {
        switch signal {
        case .rated(let r):
            // Queued rating while anyone aims is dropped, not delayed.
            guard !isAiming, !badgesLocked, !silenced.contains(r.shotID) else {
                silenced.insert(r.shotID)
                return
            }
            current = r
            isPinned = false
            generation += 1
        case .aimStarted:
            isAiming = true
            if let c = current { silenced.insert(c.shotID) }
            hide()
        case .aimEnded:
            isAiming = false
        case .badgesLocked(let locked):
            badgesLocked = locked
            if locked { hide() }
        }
    }

    func holdElapsed(generation g: Int) {
        guard g == generation, !isPinned else { return }
        hide()
    }

    func tap() {
        guard current != nil else { return }
        if isPinned { hide() } else { isPinned = true }
    }

    func swipeUp() { hide() }

    var style: RatingBadgeStyle? { current.map { RatingBadgeStyle.of($0.rating) } }

    /// VoiceOver announcement; never while aiming.
    var announcement: String? {
        guard let c = current, !isAiming else { return nil }
        return "\(RatingBadgeStyle.of(c.rating).words) shot by \(c.shooterName)"
    }

    var wantsSuccessHaptic: Bool { current?.rating == .brilliant }

    private func hide() {
        current = nil
        isPinned = false
    }
}
