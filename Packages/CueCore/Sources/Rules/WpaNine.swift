import Geometry

extension RulesEngine {
    func nineBreak(_ o: ShotOutcome, _ g: GameState) -> RuleResult { RuleResult(nextState: g) }
    func nineShot(_ o: ShotOutcome, _ g: GameState) -> RuleResult { RuleResult(nextState: g) }
}
