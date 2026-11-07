import Testing
@testable import Engine

// D18: ten chess.com-style classes, best → worst.
@Test func decisionRating_hasTenClassesInOrder() {
    #expect(DecisionRating.allCases == [
        .brilliant, .great, .best, .good, .okay, .book,
        .inaccuracy, .miss, .mistake, .blunder,
    ])
}

@Test func decisionRating_rawValuesAreStable() {
    // Persisted as raw strings (SwiftData + BackupV1) — never rename.
    #expect(DecisionRating.allCases.map(\.rawValue) == [
        "brilliant", "great", "best", "good", "okay", "book",
        "inaccuracy", "miss", "mistake", "blunder",
    ])
}

@Test func decisionRating_specialAndNegativeGroups() {
    #expect(DecisionRating.allCases.filter(\.isSpecial) == [.brilliant, .great])
    #expect(DecisionRating.allCases.filter(\.isNegative) == [.inaccuracy, .miss, .mistake, .blunder])
}
