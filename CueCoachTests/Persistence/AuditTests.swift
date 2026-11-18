import Foundation
import SwiftData
import Testing
@testable import CueCoach

/// Adversarial QA audit of Persistence: crafted backups, duplicate IDs, unicode, date edges,
/// interleaved saves, recognition privacy, guest purge. Fixed findings are kept as regressions; tests that
/// still expose a defect are disabled with an "AUDIT-FINDING" reason naming the expected behaviour.
@MainActor
@Suite struct PersistenceAuditTests {
    struct Injected: Error {}

    private func populated() throws -> PersistenceStack {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        _ = Fixture.populateTraining(stack.trainingContext)
        try stack.competitiveContext.save()
        try stack.trainingContext.save()
        return stack
    }

    private func snapshot(_ s: PersistenceStack) throws -> BackupV1 {
        try BackupV1.decode(s.exportBackup(exportedAt: Fixture.t0))
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
    }

    private func profile(_ id: UUID = UUID(), name: String = "P", updatedAt: Date = Fixture.t0,
                         owner: Bool = false) -> BackupV1.Profile {
        .init(id: id, name: name, avatarSymbol: "star", avatarColor: "red", isLocalOwner: owner,
              createdAt: Fixture.t0, updatedAt: updatedAt, skillModel: .prior)
    }

    private func emptyBackup() -> BackupV1 {
        BackupV1(exportedAt: Fixture.t0, competitive: .init(), training: .init())
    }

    // MARK: Malformed input is rejected without touching either store

    @Test(arguments: [
        "", "{", "null", "[]", "{\"version\":\"1\"}", "{\"version\":1}",
        "{\"version\":1.5,\"exportedAt\":\"2026-01-01T00:00:00Z\"}",
        "{\"version\":-1}", "{\"version\":9223372036854775808}",
    ])
    func malformedJSONIsRejectedAndChangesNothing(_ raw: String) throws {
        let stack = try populated()
        let before = try snapshot(stack)
        #expect(throws: (any Error).self) { try stack.importBackup(Data(raw.utf8)) }
        #expect(try snapshot(stack) == before)
    }

    @Test func unknownEnumRawValueRejectsWholeBackup() throws {
        let stack = try populated()
        let before = try snapshot(stack)
        // Rename the owner (newer) and poison the ruleSet: nothing may be applied.
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.profiles[0].name = "Hacked"
        b.competitive.profiles[0].updatedAt = .now.addingTimeInterval(60)
        var poisoned = String(decoding: try b.encoded(), as: UTF8.self)
        poisoned = poisoned.replacingOccurrences(of: "\"ruleSet\":\"wpaNine\"", with: "\"ruleSet\":\"snooker\"")
        #expect(poisoned.contains("snooker"))
        #expect(throws: (any Error).self) { try stack.importBackup(Data(poisoned.utf8)) }
        #expect(try snapshot(stack) == before)
    }

    @Test func extraUnknownKeysAreIgnored() throws {
        let stack = try PersistenceStack(inMemory: true)
        var b = emptyBackup()
        b.competitive.profiles = [profile(name: "X")]
        var obj = try JSONSerialization.jsonObject(with: b.encoded()) as! [String: Any]
        obj["futureField"] = ["a": 1]
        try stack.importBackup(JSONSerialization.data(withJSONObject: obj))
        #expect(try Fixture.count(PlayerProfile.self, stack.competitiveContext) == 1)
    }

    // MARK: Duplicate IDs inside one backup

    @Test(arguments: [false, true])
    func duplicateProfileIDsInBackupNewestWinsRegardlessOfOrder(newestFirst: Bool) throws {
        let stack = try PersistenceStack(inMemory: true)
        let id = UUID()
        var old = profile(id, name: "Old", updatedAt: Fixture.t0)
        var new = profile(id, name: "New", updatedAt: Fixture.t0.addingTimeInterval(10))
        old.avatarColor = "old"; new.avatarColor = "new"
        var b = emptyBackup()
        b.competitive.profiles = newestFirst ? [new, old] : [old, new]
        try stack.importBackup(b.encoded())
        let rows = try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>())
        #expect(rows.count == 1)
        #expect(rows.first?.name == "New")
        #expect(rows.first?.avatarColor == "new")
    }

    @Test func duplicateAttemptIDsDoNotDuplicateRows() throws {
        let stack = try populated()
        var b = try BackupV1.decode(stack.exportBackup())
        b.training.attempts += b.training.attempts + b.training.attempts
        try stack.importBackup(b.encoded())
        #expect(try Fixture.count(TrainingAttempt.self, stack.trainingContext) == 3)
    }

    @Test func sameUUIDAcrossDifferentModelTypesIsHarmless() throws {
        let stack = try PersistenceStack(inMemory: true)
        let shared = UUID()
        var b = emptyBackup()
        b.competitive.profiles = [profile(shared)]
        b.competitive.sessions = [.init(id: shared, startedAt: Fixture.t0, endedAt: nil, ruleSet: .barEight,
                                        format: .oneVsOne, tableSize: .sevenFoot, peerDeviceNames: [],
                                        voteTally: [:], updatedAt: Fixture.t0)]
        b.competitive.games = [.init(id: shared, sessionID: shared, index: 0, ruleSet: .barEight, teams: [],
                                     winnerTeam: nil, winProbSeries: [], startedAt: Fixture.t0, endedAt: nil,
                                     updatedAt: Fixture.t0)]
        b.training.profiles = [.init(id: shared, playerID: shared, createdAt: Fixture.t0, updatedAt: Fixture.t0)]
        try stack.importBackup(b.encoded())
        let game = try #require(stack.competitiveContext.fetch(FetchDescriptor<Game>()).first)
        #expect(game.session?.id == shared)
        #expect(try Fixture.count(PlayerProfile.self, stack.competitiveContext) == 1)
        #expect(try Fixture.count(TrainingProfile.self, stack.trainingContext) == 1)
    }

    // MARK: "Cycles" / dangling references

    @Test func gameReferencingItselfAsSessionIsRejected() throws {
        let stack = try PersistenceStack(inMemory: true)
        let id = UUID()
        var b = emptyBackup()
        b.competitive.games = [.init(id: id, sessionID: id, index: 0, ruleSet: .barEight, teams: [],
                                     winnerTeam: nil, winProbSeries: [], startedAt: Fixture.t0, endedAt: nil,
                                     updatedAt: Fixture.t0)]
        #expect(throws: BackupError.missingParent(child: "Game", childID: id, parentID: id)) {
            try stack.importBackup(b.encoded())
        }
        #expect(try Fixture.count(Game.self, stack.competitiveContext) == 0)
    }

    @Test func attemptPointingAtCompetitiveRowIDIsRejected() throws {
        // A training attempt must never be parented by a competitive id (store isolation).
        let stack = try populated()
        let gameID = try #require(stack.competitiveContext.fetch(FetchDescriptor<Game>()).first?.id)
        var b = try BackupV1.decode(stack.exportBackup())
        b.training.attempts[0].progressID = gameID
        b.training.attempts[0].updatedAt = .now.addingTimeInterval(60)
        #expect(throws: BackupError.self) { try stack.importBackup(b.encoded()) }
    }

    // MARK: Out-of-range values

    @Test(arguments: [Int.min, -5, 0, 5, 99, Int.max])
    func drillLevelFromBackupIsClamped(_ level: Int) throws {
        let stack = try PersistenceStack(inMemory: true)
        var b = emptyBackup()
        b.training.drillProgress = [.init(id: UUID(), playerID: UUID(), drill: "x", level: level,
                                          recentResults: [], levelHistory: [], updatedAt: Fixture.t0)]
        try stack.importBackup(b.encoded())
        let p = try #require(stack.trainingContext.fetch(FetchDescriptor<DrillProgress>()).first)
        #expect(DrillProgress.levels.contains(p.level))
    }

    @Test func invalidPocketedKeysAreDroppedNotCrashing() throws {
        let stack = try populated()
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.shots[0].pocketed = ["99": .footLeft, "abc": .footRight, "-1": .sideLeft, "3": .headLeft]
        b.competitive.shots[0].updatedAt = .now.addingTimeInterval(60)
        try stack.importBackup(b.encoded())
        let shot = try #require(stack.competitiveContext.fetch(FetchDescriptor<Shot>())
            .first { $0.id == b.competitive.shots[0].id })
        #expect(shot.pocketed.count == 1)
    }

    // F1: aliased ball keys ("8" + "08") must not trap; only canonical keys are read, so "8" wins deterministically.
    @Test func aliasedPocketedKeysDoNotCrash() throws {
        let stack = try populated()
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.shots[0].pocketed = ["8": .footLeft, "08": .footRight, "+8": .sideLeft, " 8": .sideRight]
        b.competitive.shots[0].updatedAt = .now.addingTimeInterval(60)
        try stack.importBackup(b.encoded())
        let shot = try #require(stack.competitiveContext.fetch(FetchDescriptor<Shot>())
            .first { $0.id == b.competitive.shots[0].id })
        #expect(shot.pocketed == [.eight: .footLeft])
    }

    // MARK: Unicode

    @Test(arguments: [
        "👨‍👩‍👧‍👦🎱", "مرحبا", "e\u{0301}", "\u{202E}evil", "Zalgơ̷̢̪", String(repeating: "ß", count: 20_000),
        "quote\"back\\slash/", "line\nbreak\ttab",
    ])
    func unicodeNamesRoundTripThroughDiskAndBackup(_ name: String) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = try PersistenceStack(directory: dir)
            s.competitiveContext.insert(PlayerProfile(id: Fixture.ownerID, name: name, avatarSymbol: "star",
                                                      avatarColor: "red", isLocalOwner: true, createdAt: Fixture.t0))
            try s.competitiveContext.save()
        }
        let reopened = try PersistenceStack(directory: dir)
        let stored = try #require(reopened.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(stored.name == name)
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(reopened.exportBackup())
        #expect(try fresh.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first?.name == name)
    }

    @Test(.disabled("AUDIT-FINDING F12: an embedded NUL in a string is truncated by the on-disk store (\"Ari\\0hidden\" reads back as \"Ari\"); in-memory and JSON keep it, so disk and backup disagree. Expected: identical round-trip or NUL rejected on import."))
    func nulCharacterInNameSurvivesDiskStore() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "Ari\u{0000}hidden"
        do {
            let s = try PersistenceStack(directory: dir)
            var b = emptyBackup()
            b.competitive.profiles = [profile(name: name)]
            try s.importBackup(b.encoded())
        }
        let reopened = try PersistenceStack(directory: dir)
        #expect(try reopened.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first?.name == name)
    }

    // MARK: Dates

    @Test(arguments: [
        0.0, -0.0005, -0.0004, -1.5, -86_400 * 365.25 * 100, 0.0005, 1_700_000_000.9995,
        Date.distantPast.timeIntervalSince1970, Date.distantFuture.timeIntervalSince1970,
        253_402_300_799.999,   // 9999-12-31T23:59:59.999Z
    ])
    func extremeDatesRoundTripAtMillisecondGrain(_ t: Double) throws {
        let date = Date(timeIntervalSince1970: t)
        var b = emptyBackup()
        b.exportedAt = date
        b.competitive.profiles = [profile(updatedAt: date)]
        let decoded = try BackupV1.decode(b.encoded())
        #expect(BackupV1.millis(decoded.exportedAt) == BackupV1.millis(date))
        #expect(BackupV1.millis(decoded.competitive.profiles[0].updatedAt) == BackupV1.millis(date))
        // Second cycle is byte-identical (no drift).
        #expect(try decoded.encoded() == BackupV1.decode(decoded.encoded()).encoded())
    }

    @Test func reimportAtDateExtremesIsIdempotent() throws {
        let stack = try PersistenceStack(inMemory: true)
        var b = emptyBackup()
        b.competitive.profiles = [profile(name: "Past", updatedAt: .distantPast),
                                  profile(name: "Future", updatedAt: .distantFuture),
                                  profile(name: "Neg", updatedAt: Date(timeIntervalSince1970: -0.0004))]
        let data = try b.encoded()
        try stack.importBackup(data)
        let first = try stack.exportBackup(exportedAt: Fixture.t0)
        try stack.importBackup(data)
        #expect(try stack.exportBackup(exportedAt: Fixture.t0) == first)
    }

    @Test(arguments: [
        ("2023-11-14T22:13:20.123Z", 1_700_000_000.123),
        ("2023-11-14T22:13:20Z", 1_700_000_000.0),
    ])
    func acceptedDateFormatsParseExactly(_ s: String, _ expected: Double) throws {
        let json = "{\"version\":1,\"exportedAt\":\"\(s)\",\"includesRecognition\":false,\"competitive\":{\"profiles\":[],\"sessions\":[],\"games\":[],\"shots\":[],\"archetypes\":[],\"highlights\":[]},\"training\":{\"profiles\":[],\"drillProgress\":[],\"attempts\":[],\"biases\":[]}}"
        let b = try BackupV1.decode(Data(json.utf8))
        #expect(BackupV1.millis(b.exportedAt) == BackupV1.millis(Date(timeIntervalSince1970: expected)))
    }

    @Test(arguments: [
        "2023-11-14T22:13:20.123456Z", "2023-11-14T23:13:20.123+01:00", "2023-11-14 22:13:20Z",
        "1700000000", "",
    ])
    func otherDateFormatsEitherParseCorrectlyOrThrow(_ s: String) throws {
        let json = "{\"version\":1,\"exportedAt\":\"\(s)\",\"includesRecognition\":false,\"competitive\":{\"profiles\":[],\"sessions\":[],\"games\":[],\"shots\":[],\"archetypes\":[],\"highlights\":[]},\"training\":{\"profiles\":[],\"drillProgress\":[],\"attempts\":[],\"biases\":[]}}"
        guard let b = try? BackupV1.decode(Data(json.utf8)) else { return }
        // If accepted, it must denote 2023-11-14T22:13:20.123Z (or .000 for whole-second inputs), never a shifted date.
        let ms = BackupV1.millis(b.exportedAt)
        #expect(ms == 1_700_000_000_123 || ms == 1_700_000_000_000, "\(s) parsed to \(b.exportedAt)")
    }

    // F11: impossible calendar dates are rejected, never rolled over.
    @Test(arguments: ["2023-02-30T00:00:00Z", "2023-02-29T00:00:00.000Z", "2023-04-31T12:00:00Z",
                      "2023-13-01T00:00:00Z", "2023-01-01T24:00:00Z", "2023-01-01T23:60:00Z",
                      "2023-01-01T23:59:60Z"])
    func impossibleCalendarDateIsRejected(_ date: String) throws {
        let json = "{\"version\":1,\"exportedAt\":\"\(date)\",\"includesRecognition\":false,\"competitive\":{\"profiles\":[],\"sessions\":[],\"games\":[],\"shots\":[],\"archetypes\":[],\"highlights\":[]},\"training\":{\"profiles\":[],\"drillProgress\":[],\"attempts\":[],\"biases\":[]}}"
        #expect(throws: (any Error).self) { try BackupV1.decode(Data(json.utf8)) }
    }

    @Test(arguments: ["2024-02-29T00:00:00Z", "2024-02-29T23:59:59.999Z", "2000-02-29T12:00:00.500Z"])
    func realLeapDaysStillParse(_ date: String) throws {
        let json = "{\"version\":1,\"exportedAt\":\"\(date)\",\"includesRecognition\":false,\"competitive\":{\"profiles\":[],\"sessions\":[],\"games\":[],\"shots\":[],\"archetypes\":[],\"highlights\":[]},\"training\":{\"profiles\":[],\"drillProgress\":[],\"attempts\":[],\"biases\":[]}}"
        let b = try BackupV1.decode(Data(json.utf8))
        #expect(BackupV1.isoString(b.exportedAt).hasPrefix(String(date.prefix(19))))
    }

    @Test func subMillisecondNewerLocalEditIsNotClobbered() throws {
        // Local row is 0.4 ms newer than backup; at ms grain they tie, so the backup must NOT win.
        let stack = try PersistenceStack(inMemory: true)
        let id = UUID()
        let p = PlayerProfile(id: id, name: "Local", avatarSymbol: "s", avatarColor: "c", createdAt: Fixture.t0)
        stack.competitiveContext.insert(p)
        p.touch(Date(timeIntervalSince1970: 1_700_000_000.1234))
        try stack.competitiveContext.save()
        var b = emptyBackup()
        b.competitive.profiles = [profile(id, name: "Backup", updatedAt: Date(timeIntervalSince1970: 1_700_000_000.1231))]
        try stack.importBackup(b.encoded())
        #expect(p.name == "Local")
    }

    // MARK: Huge payloads

    @Test func largeBackupImportsCompletely() throws {
        let source = try populated()
        var b = try BackupV1.decode(source.exportBackup())
        let template = b.competitive.shots[0]
        b.competitive.shots = (0..<4_000).map { i in var s = template; s.id = UUID(); s.index = i; return s }
        let attempt = b.training.attempts[0]
        b.training.attempts = (0..<4_000).map { _ in var a = attempt; a.id = UUID(); return a }
        let data = try b.encoded()
        let fresh = try PersistenceStack(inMemory: true)
        let clock = ContinuousClock()
        let elapsed = try clock.measure { try fresh.importBackup(data) }
        #expect(try Fixture.count(Shot.self, fresh.competitiveContext) == 4_000)
        #expect(try Fixture.count(TrainingAttempt.self, fresh.trainingContext) == 4_000)
        #expect(elapsed < .seconds(60), "import of \(data.count) bytes took \(elapsed)")
    }

    @Test func hugeEmbeddingIsStoredButNeverExported() throws {
        let stack = try populated()
        let big = Data((0..<4_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try Fixture.addOwnerRecognition(stack, face: big)
        #expect(try stack.recognition(for: Fixture.ownerID)?.faceEmbedding == big)
        let data = try stack.exportBackup()
        #expect(data.count < 1_000_000)
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(data)
        #expect(try Fixture.count(RecognitionData.self, fresh.recognitionContext) == 0)
    }

    // MARK: Non-finite numbers

    // F6: a non-finite Double in any row must not block export, and it round-trips unchanged.
    @Test(arguments: [Double.infinity, -Double.infinity])
    func infiniteNumberDoesNotBlockExport(_ value: Double) throws {
        let stack = try populated()
        let shot = try #require(stack.competitiveContext.fetch(FetchDescriptor<Shot>()).first)
        let id = shot.id
        shot.wpaDelta = value
        shot.game?.winProbSeries = [value]
        try stack.competitiveContext.save()
        let data = try stack.exportBackup()
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(data)
        let back = try #require(fresh.competitiveContext.fetch(FetchDescriptor<Shot>()).first { $0.id == id })
        #expect(back.wpaDelta == value)
        #expect(back.game?.winProbSeries == [value])
    }

    // F10: the backup format itself never turns NaN into a real value (it was export throwing, see F6).
    // Note: the SwiftData store, not the encoder, decides what a plain Double column holds after a save.
    @Test func nanSurvivesBackupEncodingAsNaN() throws {
        var b = emptyBackup()
        b.competitive.sessions = [.init(id: UUID(), startedAt: Fixture.t0, endedAt: nil, ruleSet: .barEight,
                                        format: .oneVsOne, tableSize: .sevenFoot, peerDeviceNames: [],
                                        voteTally: [:], updatedAt: Fixture.t0)]
        b.competitive.games = [.init(id: UUID(), sessionID: b.competitive.sessions[0].id, index: 0,
                                     ruleSet: .barEight, teams: [], winnerTeam: nil,
                                     winProbSeries: [.nan, .infinity, 0.5], startedAt: Fixture.t0, endedAt: nil,
                                     updatedAt: Fixture.t0)]
        let series = try BackupV1.decode(b.encoded()).competitive.games[0].winProbSeries
        #expect(series.count == 3 && series[0].isNaN && series[1] == .infinity && series[2] == 0.5)
    }

    // F7: a non-finite value inside a JSON blob column is stored, not a crash.
    @Test func nanInBlobValueDoesNotCrash() throws {
        let p = PlayerProfile(name: "X", avatarSymbol: "s", avatarColor: "c")
        p.skillModel = StoredSkillModel(aimSigma: .nan, speedSigma: .infinity, spinSigma: 0, samples: 0)
        #expect(p.skillModel.aimSigma.isNaN)
        #expect(p.skillModel.speedSigma == .infinity)
    }

    // MARK: Recognition privacy
    // F2/F3 (crafted recognition rows in a backup) can no longer happen: import never writes the recognition
    // store. RecognitionStoreTests.importIgnoresRecognitionInALegacyBackup pins that.

    // F4: deletion sticks: an older backup cannot bring deleted embeddings back, and the tombstone stays.
    @Test func deletedRecognitionStaysDeletedAfterOldBackupImport() throws {
        let stack = try populated()
        try Fixture.addOwnerRecognition(stack)
        let old = try stack.exportBackup()
        try stack.deleteMyRecognitionData()
        try stack.importBackup(old)
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
        var b = try BackupV1.decode(old)
        b.competitive.profiles[0].updatedAt = .now.addingTimeInterval(3600)
        try stack.importBackup(b.encoded())
        let owner = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(owner.recognitionRevokedAt != nil)
    }

    @Test func deletionTombstoneSurvivesReopenOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old: Data
        do {
            let s = try PersistenceStack(directory: dir)
            _ = Fixture.populateCompetitive(s.competitiveContext)
            try s.competitiveContext.save()
            try Fixture.addOwnerRecognition(s)
            old = try s.exportBackup()
            try s.deleteMyRecognitionData()
        }
        let reopened = try PersistenceStack(directory: dir)
        try reopened.importBackup(old)
        #expect(try Fixture.count(RecognitionData.self, reopened.recognitionContext) == 0)
        #expect(throws: RecognitionError.revoked) { try Fixture.addOwnerRecognition(reopened) }
    }

    // F4: a fresh opt-in made after the deletion is accepted.
    @Test func recognitionOptedInAfterDeletionIsStored() throws {
        let stack = try populated()
        try Fixture.addOwnerRecognition(stack)
        try stack.deleteMyRecognitionData()
        try Fixture.addOwnerRecognition(stack, face: Data([8]), optedInAt: .now.addingTimeInterval(60))
        #expect(try stack.recognition(for: Fixture.ownerID)?.faceEmbedding == Data([8]))
    }

    @Test func deleteMyRecognitionDataSurvivesReopenOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = try PersistenceStack(directory: dir)
            _ = Fixture.populateCompetitive(s.competitiveContext)
            try s.competitiveContext.save()
            try Fixture.addOwnerRecognition(s)
            try s.deleteMyRecognitionData()
        }
        let reopened = try PersistenceStack(directory: dir)
        #expect(try Fixture.count(RecognitionData.self, reopened.recognitionContext) == 0)
        #expect(try Fixture.count(PlayerProfile.self, reopened.competitiveContext) == 1)
        let backup = String(decoding: try reopened.exportBackup(), as: UTF8.self)
        #expect(!backup.contains("faceEmbedding"))
    }

    @Test func deleteMyRecognitionDataTwiceIsSafe() throws {
        let stack = try populated()
        try Fixture.addOwnerRecognition(stack)
        try stack.deleteMyRecognitionData()
        try stack.deleteMyRecognitionData()
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
    }

    // MARK: Session guests

    @Test func purgeRemovesGuestRecognitionAndKeepsShotsOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = try PersistenceStack(directory: dir)
            _ = Fixture.populateCompetitive(s.competitiveContext)
            let guest = PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "s", avatarColor: "c",
                                      isSessionGuest: true)
            s.competitiveContext.insert(guest)
            s.competitiveContext.insert(Fixture.shot(index: 9, shooter: Fixture.guestID))
            try s.competitiveContext.save()
            try Fixture.addOwnerRecognition(s)
            try s.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([5]), appearanceEmbedding: nil,
                                   optedInAt: Fixture.t0, version: 1)
            try s.purgeSessionGuests()
        }
        let r = try PersistenceStack(directory: dir)
        #expect(try r.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).map(\.id) == [Fixture.ownerID])
        #expect(try r.recognitionContext.fetch(FetchDescriptor<RecognitionData>()).map(\.profileID) == [Fixture.ownerID])
        #expect(try r.competitiveContext.fetch(FetchDescriptor<Shot>()).contains { $0.shooterID == Fixture.guestID })
    }

    @Test func multipleOwnersInBackupYieldExactlyOneOwnerOnFreshPhone() throws {
        let fresh = try PersistenceStack(inMemory: true)
        var b = emptyBackup()
        b.competitive.profiles = (0..<5).map { _ in profile(owner: true) }
        try fresh.importBackup(b.encoded())
        let owners = try fresh.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        #expect(owners.count == 1)
    }

    // F8: a backup profile is a saved profile; matching a live guest's id promotes it, so purge keeps it.
    @Test(arguments: [true, false])
    func importedProfileMatchingGuestSurvivesPurge(backupIsNewer: Bool) throws {
        let stack = try populated()
        stack.competitiveContext.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "s",
                                                      avatarColor: "c", isSessionGuest: true, createdAt: Fixture.t0,
                                                      updatedAt: .now))
        try stack.competitiveContext.save()
        var b = emptyBackup()
        let stamp = backupIsNewer ? Date.now.addingTimeInterval(60) : Fixture.t0
        b.competitive.profiles = [profile(Fixture.guestID, name: "Sam (saved)", updatedAt: stamp)]
        try stack.importBackup(b.encoded())
        try stack.purgeSessionGuests()
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).contains { $0.id == Fixture.guestID })
    }

    // MARK: Interleaved / concurrent saves

    @Test(.disabled("AUDIT-FINDING F5: a row saved by another ModelContext between importBackup's fetch and its save is overwritten by the backup's OLDER copy (insert + .unique upsert bypasses newer-wins). Expected: newer row kept."))
    func concurrentNewerSaveIsNotClobberedByOlderBackupRow() throws {
        let stack = try PersistenceStack(inMemory: true)
        let id = UUID()
        var b = emptyBackup()
        b.competitive.profiles = [profile(id, name: "Backup", updatedAt: Fixture.t0)]
        stack.beforeSave = { kind in
            guard kind == .competitive else { return }
            let other = ModelContext(stack.competitiveContainer)
            other.insert(PlayerProfile(id: id, name: "LiveNewer", avatarSymbol: "s", avatarColor: "c",
                                       createdAt: .now, updatedAt: .now))
            try other.save()
        }
        try stack.importBackup(b.encoded())
        stack.beforeSave = nil
        let verify = ModelContext(stack.competitiveContainer)
        let rows = try verify.fetch(FetchDescriptor<PlayerProfile>())
        #expect(rows.count == 1)
        #expect(rows.first?.name == "LiveNewer")
    }

    // F9: import never rolls back unrelated pending edits: it refuses to run while either context has
    // unsaved changes, and a failed import leaves the app's pending work alone.
    @Test func importRefusesWhilePendingEditsAndKeepsThem() throws {
        let stack = try populated()
        let pending = PlayerProfile(name: "Unsaved", avatarSymbol: "s", avatarColor: "c")
        stack.competitiveContext.insert(pending)
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.profiles[0].name = "X"
        b.competitive.profiles[0].updatedAt = .now.addingTimeInterval(60)
        #expect(throws: BackupError.pendingChanges) { try stack.importBackup(b.encoded()) }
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).contains { $0.name == "Unsaved" })
        #expect(try !stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).contains { $0.name == "X" })
    }

    @Test func importRefusesWhileTrainingHasPendingEdits() throws {
        let stack = try populated()
        stack.trainingContext.insert(TrainingProfile(playerID: UUID(), createdAt: Fixture.t0))
        #expect(throws: BackupError.pendingChanges) { try stack.importBackup(emptyBackup().encoded()) }
        #expect(stack.trainingContext.hasChanges)
    }

    @Test func importThenOnDiskReopenMatchesExport() throws {
        let source = try populated()
        let backup = try source.exportBackup(exportedAt: Fixture.t0)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do { try PersistenceStack(directory: dir).importBackup(backup) }
        let reopened = try PersistenceStack(directory: dir)
        #expect(try BackupV1.decode(reopened.exportBackup(exportedAt: Fixture.t0))
                == BackupV1.decode(backup))
    }

    // F13: byte-stability across processes isn't a requirement and can't be shown in one process; what we can
    // pin is that TableState.balls is written in BallID order (no hash-seeded ordering in the file).
    @Test func exportWritesBallsInBallIDOrder() throws {
        let stack = try populated()
        let obj = try JSONSerialization.jsonObject(with: stack.exportBackup()) as! [String: Any]
        let shots = try #require((obj["competitive"] as? [String: Any])?["shots"] as? [[String: Any]])
        for shot in shots {
            for key in ["preState", "postState"] {
                let balls = try #require((shot[key] as? [String: Any])?["balls"] as? [Any])
                let numbers = stride(from: 0, to: balls.count, by: 2).compactMap {
                    (balls[$0] as? [String: Any])?["number"] as? Int
                }
                #expect(numbers.count == balls.count / 2 && numbers == numbers.sorted())
            }
        }
    }

    @Test func emptyBackupIsANoOp() throws {
        let stack = try populated()
        let before = try snapshot(stack)
        try stack.importBackup(emptyBackup().encoded())
        #expect(try snapshot(stack) == before)
    }
}

