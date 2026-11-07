import Foundation
import SwiftData
import Geometry
import Rules
import Engine
@testable import CueCoach

/// Deterministic sample data shared by the persistence tests.
@MainActor
enum Fixture {
    static let ownerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let guestID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000.123)

    static func table() -> TableState {
        var s = TableState(spec: TableSpec(size: .sevenFoot))
        s.balls[.cue] = BallState(position: Vec2(0.5, 0.4))
        s.balls[.eight] = BallState(position: Vec2(1.5, 0.5))
        s.balls[BallID(3)!] = BallState(position: Vec2(1.0, 0.2), motion: .pocketed)
        return s
    }

    static func owner() -> PlayerProfile {
        PlayerProfile(id: ownerID, name: "Ari", avatarSymbol: "figure.pool.swim", avatarColor: "teal",
                      isLocalOwner: true, createdAt: t0,
                      skillModel: StoredSkillModel(aimSigma: 0.01, speedSigma: 0.05, spinSigma: 0.1, samples: 12))
    }

    static func recognition() -> RecognitionData {
        RecognitionData(faceEmbedding: Data([1, 2, 3]), appearanceEmbedding: Data([4, 5]),
                        optedInAt: t0, version: 1)
    }

    static func shot(index: Int, shooter: UUID = ownerID) -> Shot {
        Shot(index: index, shooterID: shooter, attributionSource: .auto,
             preState: table(), postState: table(), calledPocket: .footLeft, firstContact: .eight,
             railsAfterContact: 1, pocketed: [.eight: .footLeft], fouls: [.wrongBallFirst(BallID(2)!)],
             features: StoredShotFeatures(cutBucket: .c15to30, distanceBucket: .mid, pocketType: .corner, kind: .bank),
             made: true, onTarget: true, cueResult: .inZone, decisionRating: .great,
             executionRating: ExecutionRating(result: .made, position: .inZone),
             wpaDelta: 0.12, isClutch: false, timeOnShot: 8.5, clipRef: "clips/a.mov")
    }

    /// Session with one game, two shots and one highlight, plus owner + archetype.
    static func populateCompetitive(_ ctx: ModelContext) -> Session {
        let owner = owner()
        owner.recognition = recognition()
        ctx.insert(owner)
        let session = Session(startedAt: t0, ruleSet: .wpaNine, format: .oneVsOne, tableSize: .eightFoot,
                              peerDeviceNames: ["Pixel"], voteTally: [.wpaNine: 2, .barEight: 1])
        ctx.insert(session)
        let game = Game(index: 0, ruleSet: .wpaNine,
                        teams: [StoredTeam(memberIDs: [ownerID], shootingOrder: [ownerID]),
                                StoredTeam(memberIDs: [guestID], shootingOrder: [guestID])],
                        winnerTeam: 0, winProbSeries: [0.5, 0.62], startedAt: t0)
        game.session = session
        ctx.insert(game)
        for i in 0..<2 { let s = shot(index: i); s.game = game; ctx.insert(s) }
        let h = Highlight(shotID: UUID(), kind: .shotOfGame, clipFile: "clips/h.mov", label: "Bank Shot", score: 0.9)
        h.game = game
        ctx.insert(h)
        ctx.insert(ArchetypeSnapshot(playerID: ownerID, computedAt: t0, gamesCount: 3, shotsCount: 60,
                                     vector: ["cut": 1.2, "long": -0.3], tags: ["cutArtist"],
                                     proComp: StoredProComp(proID: "efren", similarity: 0.81, sharedTraits: ["cut", "bank"])))
        return session
    }

    static func populateTraining(_ ctx: ModelContext) -> DrillProgress {
        ctx.insert(TrainingProfile(playerID: ownerID, createdAt: t0))
        let p = DrillProgress(playerID: ownerID, drill: "straightIns", level: 2, recentResults: [true, false, true],
                              levelHistory: [LevelChange(at: t0, from: 1, to: 2)])
        ctx.insert(p)
        for _ in 0..<3 {
            let a = TrainingAttempt(at: t0, setup: table(), result: table(), made: true,
                                    features: StoredAttemptFeatures(signedCutError: -0.02, signedSpeedError: 0.1,
                                                                    cueLandingError: 0.05, spinIntended: 0.3, spinObserved: 0.1))
            a.progress = p
            ctx.insert(a)
        }
        ctx.insert(BiasRecord(playerID: ownerID, drill: "straightIns", axis: .cut, sign: 1, attemptsWindow: 8, detectedAt: t0))
        return p
    }

    static func count<T: PersistentModel>(_ type: T.Type, _ ctx: ModelContext) throws -> Int {
        try ctx.fetchCount(FetchDescriptor<T>())
    }
}
