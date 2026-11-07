import Foundation
import Testing
import Engine
@testable import CueCoach

@MainActor
@Suite struct PostShotBadgeModelTests {
    func rating(_ r: DecisionRating = .great, id: UUID = UUID()) -> PostShotRating {
        PostShotRating(shotID: id, rating: r, shooterName: "Sam", team: 1)
    }

    @Test func showsRatingAfterSettle() {
        let m = PostShotBadgeModel()
        m.receive(.rated(rating(.brilliant)))
        #expect(m.current?.rating == .brilliant)
        #expect(m.announcement == "Brilliant shot by Sam")
    }

    @Test func autoDismissesAfterHold() {
        let m = PostShotBadgeModel()
        m.receive(.rated(rating()))
        let gen = m.generation
        m.holdElapsed(generation: gen)
        #expect(m.current == nil)
    }

    @Test func staleHoldTimerDoesNotDismissNewerBadge() {
        let m = PostShotBadgeModel()
        m.receive(.rated(rating()))
        let old = m.generation
        m.receive(.rated(rating(.blunder)))
        m.holdElapsed(generation: old)
        #expect(m.current?.rating == .blunder)
    }

    @Test func aimStartHidesInstantlyAndNeverReappearsForThatShot() {
        let m = PostShotBadgeModel()
        let r = rating()
        m.receive(.rated(r))
        m.receive(.aimStarted)
        #expect(m.current == nil)
        m.receive(.aimEnded)
        m.receive(.rated(r))   // re-delivered rating for the same shot
        #expect(m.current == nil)
    }

    @Test func ratingWhileAimingIsDroppedNotDelayed() {
        let m = PostShotBadgeModel()
        let r = rating()
        m.receive(.aimStarted)
        m.receive(.rated(r))
        #expect(m.current == nil)
        #expect(m.announcement == nil)
        m.receive(.aimEnded)
        #expect(m.current == nil)
    }

    @Test func tapPinsThenSecondTapDismisses() {
        let m = PostShotBadgeModel()
        m.receive(.rated(rating()))
        m.tap()
        #expect(m.isPinned)
        m.holdElapsed(generation: m.generation)
        #expect(m.current != nil)
        m.tap()
        #expect(m.current == nil)
        #expect(!m.isPinned)
    }

    @Test func pinnedBadgeStillHidesOnAim() {
        let m = PostShotBadgeModel()
        m.receive(.rated(rating()))
        m.tap()
        m.receive(.aimStarted)
        #expect(m.current == nil)
        #expect(!m.isPinned)
    }

    @Test func swipeUpDismissesEarly() {
        let m = PostShotBadgeModel()
        m.receive(.rated(rating()))
        m.swipeUp()
        #expect(m.current == nil)
    }

    @Test func trainingLockHidesBadges() {
        let m = PostShotBadgeModel(badgesLocked: true)
        m.receive(.rated(rating()))
        #expect(m.current == nil)
        m.receive(.badgesLocked(false))
        m.receive(.rated(rating()))
        #expect(m.current != nil)
        m.receive(.badgesLocked(true))
        #expect(m.current == nil)
    }

    @Test func brilliantRequestsSuccessHapticOthersDoNot() {
        let m = PostShotBadgeModel()
        m.receive(.rated(rating(.good)))
        #expect(!m.wantsSuccessHaptic)
        m.receive(.rated(rating(.brilliant)))
        #expect(m.wantsSuccessHaptic)
    }

    @Test func consumesSignalSource() async {
        let src = InMemoryPostShotSignals([.rated(rating(.mistake))])
        let m = PostShotBadgeModel(source: src)
        await m.run()
        #expect(m.current?.rating == .mistake)
    }
}
