import Testing
import Engine
@testable import CueCoach

@Suite struct RatingBadgeStyleTests {
    @Test func everyClassHasADistinctSymbol() {
        let symbols = DecisionRating.allCases.map { RatingBadgeStyle.of($0).symbol }
        #expect(Set(symbols).count == DecisionRating.allCases.count)
    }

    @Test func wordsAreAtMostTwoAndNoDigits() {
        for r in DecisionRating.allCases {
            let w = RatingBadgeStyle.of(r).words
            #expect(!w.isEmpty)
            #expect(w.split(separator: " ").count <= 2, "\(r): \(w)")
            #expect(w.rangeOfCharacter(from: .decimalDigits) == nil)
        }
    }

    @Test func tableMatchesSpec() {
        #expect(RatingBadgeStyle.of(.brilliant).symbol == "sparkles")
        #expect(RatingBadgeStyle.of(.brilliant).tone == .brilliant)
        #expect(RatingBadgeStyle.of(.great).symbol == "star.fill")
        #expect(RatingBadgeStyle.of(.best).symbol == "checkmark.seal.fill")
        #expect(RatingBadgeStyle.of(.good).tone == .ink)
        #expect(RatingBadgeStyle.of(.okay).tone == .inkMuted)
        #expect(RatingBadgeStyle.of(.book).symbol == "book.closed.fill")
        #expect(RatingBadgeStyle.of(.inaccuracy).tone == .caution)
        #expect(RatingBadgeStyle.of(.miss).symbol == "scope")
        #expect(RatingBadgeStyle.of(.miss).words == "Missed chance")
        #expect(RatingBadgeStyle.of(.mistake).tone == .warn)
        #expect(RatingBadgeStyle.of(.blunder).tone == .danger)
        #expect(RatingBadgeStyle.of(.blunder).symbol == "xmark")
    }

    @Test func onlyBrilliantGlows() {
        let glowing = DecisionRating.allCases.filter { RatingBadgeStyle.of($0).glows }
        #expect(glowing == [.brilliant])
    }

    @Test func chartMarkersLimitedToFourKinds() {
        let marked = DecisionRating.allCases.filter { RatingBadgeStyle.of($0).marksChart }
        #expect(marked == [.brilliant, .great, .mistake, .blunder])
    }

    @Test func bookAndOkayRecedeInTimeline() {
        let dim = DecisionRating.allCases.filter { RatingBadgeStyle.of($0).recedes }
        #expect(dim == [.okay, .book])
    }

    @Test func unratedIsDashedCircle() {
        let s = RatingBadgeStyle.of(nil)
        #expect(s.symbol == "circle.dashed")
        #expect(s.words == "Unrated")
    }
}
