import Foundation
import Geometry
import Rules
@testable import Stats

// MARK: - Competitive shot / game builders

let alice = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
let bob = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
let carol = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

func feat(_ cut: CutBucket = .c0to15, _ dist: DistanceBucket = .short,
          _ pocket: PocketType = .corner, _ kind: ShotKind = .plain) -> ShotFeatures {
    ShotFeatures(cutBucket: cut, distanceBucket: dist, pocketType: pocket, kind: kind)
}

func feat(kind: ShotKind) -> ShotFeatures { feat(.c0to15, .short, .corner, kind) }

func cshot(_ shooter: UUID, team: Int, made: Bool = false, features: ShotFeatures = feat(),
           onTarget: Bool? = nil, cue: CueResult = .notApplicable, fouled: Bool = false,
           isBreak: Bool = false, pocketedCount: Int? = nil, wpa: Double = 0,
           clutch: Bool = false, time: Double = 10) -> CompetitiveShot {
    CompetitiveShot(id: UUID(), shooterID: shooter, team: team, isBreak: isBreak, features: features,
                    made: made, onTarget: onTarget ?? made, cueResult: cue, fouls: fouled ? [.scratch] : [],
                    objectBallsPocketed: pocketedCount ?? (made ? 1 : 0), wpaDelta: wpa,
                    isClutch: clutch, timeOnShot: time)
}

func cgame(_ shots: [CompetitiveShot], winner: Int? = 0, ruleSet: RuleSetID = .barEight,
           players: [UUID: Int] = [alice: 0, bob: 1], at: Double = 0) -> CompetitiveGame {
    CompetitiveGame(id: UUID(), ruleSet: ruleSet, startedAt: Date(timeIntervalSince1970: at),
                    teamOf: players, winnerTeam: winner, shots: shots)
}
