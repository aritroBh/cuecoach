import Foundation
import CoreData
import SwiftData
import Testing
import Geometry
import Rules
import Engine
@testable import CueCoach

/// Plan 012 (D43): Competitive V2 → V3 adds `Shot.isGuess`. Old stores must open unchanged.
@MainActor
@Suite struct ShotIsGuessMigrationTests {
    /// Entity version hashes of the shipped V1 and V2 schemas, recorded at 4a50861, before V3 existed. A frozen copy that drifts
    /// changes these, and SwiftData would then fail to recognise a user's store on disk.
    static let v1Hashes =
        "ArchetypeSnapshot=Bi+a97BNCOEF5pzGPnXXoRcKFmb2+LISPbp/fEVO+zs=;Game=4A7glKfH7qB0wF8czU1JOmgMdVUCTzUmYddsLFPZjQU=;Highlight=qP2JznoUVDyzmb5+iXbK4nj/MqXjsk/CdNKz6cfG3DI=;PlayerProfile=2+z29kUzcjp83P/4KJf/FAF2vhC9VsDZPSux1xaMKVA=;RecognitionData=9YQSQblS8RW0hd8esdW4UblFD+ROwm/g0+nPENfNbCY=;Session=alt+pBDlz4+9XVyWtaYSY9/GUgpEAAWbkxhtda4lA7I=;Shot=fPj5LnPT3erKWt4371FXIV6bgof4xB8dodKlpngsgmA="
    static let v2Hashes =
        "ArchetypeSnapshot=Bi+a97BNCOEF5pzGPnXXoRcKFmb2+LISPbp/fEVO+zs=;Game=4A7glKfH7qB0wF8czU1JOmgMdVUCTzUmYddsLFPZjQU=;Highlight=qP2JznoUVDyzmb5+iXbK4nj/MqXjsk/CdNKz6cfG3DI=;PlayerProfile=3UJFD/v/RG8Z7vik4F3NI1ML7VzKRz5wyhBU4WUsSyM=;Session=alt+pBDlz4+9XVyWtaYSY9/GUgpEAAWbkxhtda4lA7I=;Shot=fPj5LnPT3erKWt4371FXIV6bgof4xB8dodKlpngsgmA="

    static func hashes(_ s: any VersionedSchema.Type) -> String {
        let model = NSManagedObjectModel.makeManagedObjectModel(for: s.models)
        guard let model else { return "no model" }
        return model.entityVersionHashesByName.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.base64EncodedString())" }.joined(separator: ";")
    }

    @Test func shippedSchemaHashesNeverChange() {
        #expect(Self.hashes(CompetitiveSchemaV1.self) == Self.v1Hashes)
        #expect(Self.hashes(CompetitiveSchemaV2.self) == Self.v2Hashes)
    }
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("v3-\(UUID().uuidString)", isDirectory: true)
    }

    static let gameIDs = [UUID(), UUID()]
    static let sessionID = UUID()
    static let highlightID = UUID()

    /// A V2 Competitive.store on disk, written with the frozen V2 types: a session, two games with two shots each,
    /// and a highlight on the second game.
    private func makeV2Store(at dir: URL) throws -> [UUID: Int] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: CompetitiveSchemaV2.self)
        let config = ModelConfiguration("Competitive", schema: schema, url: dir.appendingPathComponent("Competitive.store"),
                                        allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = ModelContext(container)
        ctx.insert(Fixture.owner())
        let session = CompetitiveSchemaV2.Session(id: Self.sessionID, startedAt: Fixture.t0, ruleSet: .barEight,
                                                  format: .oneVsOne, tableSize: .sevenFoot)
        ctx.insert(session)
        var shots: [UUID: Int] = [:]
        for (gi, gid) in Self.gameIDs.enumerated() {
            let game = CompetitiveSchemaV2.Game(
                id: gid, index: gi, ruleSet: .barEight,
                teams: [StoredTeam(memberIDs: [Fixture.ownerID], shootingOrder: [Fixture.ownerID]),
                        StoredTeam(memberIDs: [Fixture.guestID], shootingOrder: [Fixture.guestID])],
                winnerTeam: gi, startedAt: Fixture.t0, endedAt: Fixture.t0)
            game.sessionLink = session
            ctx.insert(game)
            if gi == 1 {
                let h = CompetitiveSchemaV2.Highlight(id: Self.highlightID, shotID: gid, kind: .shotOfGame,
                                                      clipFile: "clips/h.mov", label: "Bank Shot", score: 0.9,
                                                      updatedAt: Fixture.t0)
                h.gameLink = game
                ctx.insert(h)
            }
            for i in 0..<2 {
                let s = CompetitiveSchemaV2.Shot(
                    index: i, shooterID: Fixture.ownerID, attributionSource: .tap, preState: Fixture.table(),
                    postState: Fixture.table(), calledPocket: .footLeft, firstContact: .eight, railsAfterContact: 1,
                    pocketed: [.eight: .footLeft], fouls: [.scratch],
                    features: StoredShotFeatures(cutBucket: .c15to30, distanceBucket: .mid, pocketType: .corner, kind: .bank),
                    made: true, onTarget: true, cueResult: .inZone, decisionRating: .great,
                    executionRating: ExecutionRating(result: .made, position: .inZone), wpaDelta: 0.12, isClutch: true,
                    timeOnShot: 8.5, clipRef: "clips/a.mov", updatedAt: Fixture.t0)
                s.gameLink = game
                ctx.insert(s)
                shots[s.id] = gi
            }
        }
        try ctx.save()
        return shots
    }

    @Test func v2StoreOpensAsV3WithEveryShotNotAGuess() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = try makeV2Store(at: dir)

        let stack = try PersistenceStack(directory: dir)
        #expect(stack.competitiveContainer.schema.version == Schema.Version(3, 0, 0))
        let rows = try stack.competitiveContext.fetch(FetchDescriptor<Shot>())
        #expect(rows.count == 4)
        #expect(Set(rows.map(\.id)) == Set(made.keys))
        for r in rows {
            #expect(!r.isGuess)
            #expect(r.game?.id == Self.gameIDs[made[r.id] ?? -1])
            #expect(r.shooterID == Fixture.ownerID)
            #expect(r.attributionSource == .tap)
            #expect(r.preState == Fixture.table() && r.postState == Fixture.table())
            #expect(r.calledPocket == .footLeft && r.firstContact == .eight && r.railsAfterContact == 1)
            #expect(r.pocketed == [.eight: .footLeft] && r.fouls == [.scratch])
            #expect(r.features == StoredShotFeatures(cutBucket: .c15to30, distanceBucket: .mid, pocketType: .corner, kind: .bank))
            #expect(r.made && r.onTarget && r.cueResult == .inZone && r.decisionRating == .great)
            #expect(r.executionRating == ExecutionRating(result: .made, position: .inZone))
            #expect(r.wpaDelta == 0.12 && r.isClutch && r.timeOnShot == 8.5 && r.clipRef == "clips/a.mov")
            #expect(r.updatedAt == Fixture.t0)
        }
        let games = try stack.competitiveContext.fetch(FetchDescriptor<Game>()).sorted { $0.index < $1.index }
        #expect(games.map(\.id) == Self.gameIDs)
        #expect(games.map(\.winnerTeam) == [0, 1])
        #expect(games.allSatisfy { $0.shots.count == 2 && $0.session?.id == Self.sessionID })
        #expect(games.allSatisfy { $0.teams.map(\.memberIDs) == [[Fixture.ownerID], [Fixture.guestID]] })
        let session = try #require(try stack.competitiveContext.fetch(FetchDescriptor<Session>()).first)
        #expect(session.ruleSet == .barEight && session.format == .oneVsOne && session.tableSize == .sevenFoot)
        #expect(session.startedAt == Fixture.t0 && session.games.count == 2)
        let h = try #require(try stack.competitiveContext.fetch(FetchDescriptor<Highlight>()).first)
        #expect(h.id == Self.highlightID && h.game?.id == Self.gameIDs[1] && h.shotID == Self.gameIDs[1])
        #expect(h.kind == .shotOfGame && h.clipFile == "clips/h.mov" && h.label == "Bank Shot" && h.score == 0.9)
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).count == 1)
    }

    @Test func v3RoundTripsIsGuess() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids: [UUID]
        do {
            let stack = try PersistenceStack(directory: dir)
            let shots = [Fixture.shot(index: 0), Fixture.shot(index: 1)]
            shots[1].isGuess = true
            for s in shots { stack.competitiveContext.insert(s) }
            try stack.competitiveContext.save()
            ids = shots.map(\.id)
        }
        let again = try PersistenceStack(directory: dir)
        let rows = try again.competitiveContext.fetch(FetchDescriptor<Shot>())
        #expect(Set(rows.filter(\.isGuess).map(\.id)) == [ids[1]])
        #expect(rows.count == 2)
    }

    @Test func competitiveIsAtV3WithALightweightStage() throws {
        #expect(CompetitiveSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
        #expect(CompetitiveMigrationPlan.schemas.map { $0.versionIdentifier }
                == [Schema.Version(1, 0, 0), Schema.Version(2, 0, 0), Schema.Version(3, 0, 0)])
        #expect(CompetitiveMigrationPlan.stages.count == 2)
        #expect(Set(CompetitiveSchemaV3.models.map { "\($0)" }) == Set(PersistenceStack.competitiveModels.map { "\($0)" }))
        let shot = try #require(Schema(versionedSchema: CompetitiveSchemaV3.self).entities.first { $0.name == "Shot" })
        #expect(shot.attributes.contains { $0.name == "isGuessValue" })
        let old = try #require(Schema(versionedSchema: CompetitiveSchemaV2.self).entities.first { $0.name == "Shot" })
        #expect(!old.attributes.contains { $0.name == "isGuessValue" })
    }
}
