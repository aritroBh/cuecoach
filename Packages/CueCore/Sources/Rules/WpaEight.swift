import Geometry

extension RulesEngine {
    func wpaEightBreak(_ o: ShotOutcome, _ g: GameState) -> RuleResult { RuleResult(nextState: g) }
    func wpaEightShot(_ o: ShotOutcome, _ g: GameState) -> RuleResult { RuleResult(nextState: g) }
}
