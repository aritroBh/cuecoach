import Testing
@testable import Rules

@Test func defaultRuleSetIsBarEight() {
    #expect(RuleSetID.default == .barEight)
    #expect(GameFormat.fourVsFour.playersPerTeam == 4)
}
