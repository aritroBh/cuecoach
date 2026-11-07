import Testing
import Training
@testable import CueCoach

@Suite struct LiveAdapterTests {
    @Test func trainingModeCarriesTheAssistLevelNumber() {
        #expect(ShellLiveMode.training(.none) == .training(level: 4))
        #expect(ShellLiveMode.training(.full) == .training(level: 1))
    }

    @Test func onlyGameModeShowsTeamChrome() {
        #expect(ShellLiveMode.game.showsTurnChrome)
        #expect(!ShellLiveMode.training(level: 2).showsTurnChrome)
    }
}
