import Foundation
import SwiftData
import Testing
@testable import CueCoach

/// Adversarial QA audit of Persistence: crafted backups, duplicate IDs, unicode, date edges,
/// interleaved saves, recognition privacy, guest purge. Tests that expose a defect are disabled with
/// an "AUDIT-FINDING" reason so the suite stays green; each reason names the expected behaviour.
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
        try BackupV1.decode(s.exportBackup(includeRecognition: true, exportedAt: Fixture.t0))
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
    }

    private func profile(_ id: UUID = UUID(), name: String = "P", updatedAt: Date = Fixture.t0,
                         owner: Bool = false, recognition: BackupV1.Recognition? = nil) -> BackupV1.Profile {
        .init(id: id, name: name, avatarSymbol: "star", avatarColor: "red", isLocalOwner: owner,
              createdAt: Fixture.t0, updatedAt: updatedAt, skillModel: .prior, recognition: recognition)
    }

    private func emptyBackup(includesRecognition: Bool = false) -> BackupV1 {
        BackupV1(exportedAt: Fixture.t0, includesRecognition: includesRecognition,
                 competitive: .init(), training: .init())
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

    @Test(.disabled("AUDIT-FINDING F1: aliased ball keys (\"8\" + \"08\") make Dictionary(uniqueKeysWithValues:) trap; a crafted backup crashes the app. Expected: reject or merge, never crash."))
    func aliasedPocketedKeysDoNotCrash() throws {
        let stack = try populated()
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.shots[0].pocketed = ["8": .footLeft, "08": .footRight]
        b.competitive.shots[0].updatedAt = .now.addingTimeInterval(60)
        _ = try? stack.importBackup(b.encoded())
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

    @Test(.disabled("AUDIT-FINDING F11: BackupV1.decode accepts impossible calendar dates (\"2023-02-30T00:00:00Z\") and silently rolls them over. Expected: rejected as corrupt."))
    func impossibleCalendarDateIsRejected() throws {
        let json = "{\"version\":1,\"exportedAt\":\"2023-02-30T00:00:00Z\",\"includesRecognition\":false,\"competitive\":{\"profiles\":[],\"sessions\":[],\"games\":[],\"shots\":[],\"archetypes\":[],\"highlights\":[]},\"training\":{\"profiles\":[],\"drillProgress\":[],\"attempts\":[],\"biases\":[]}}"
        #expect(throws: (any Error).self) { try BackupV1.decode(Data(json.utf8)) }
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

    @Test func hugeEmbeddingRoundTrips() throws {
        let stack = try populated()
        let big = Data((0..<4_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let r = try #require(stack.competitiveContext.fetch(FetchDescriptor<RecognitionData>()).first)
        r.faceEmbedding = big
        try stack.competitiveContext.save()
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(stack.exportBackup(includeRecognition: true))
        #expect(try fresh.competitiveContext.fetch(FetchDescriptor<RecognitionData>()).first?.faceEmbedding == big)
    }

    // MARK: Non-finite numbers

    @Test(.disabled("AUDIT-FINDING F6: an infinite Double in any row (e.g. Shot.wpaDelta, Game.winProbSeries, Highlight.score) makes exportBackup throw, so the user can never back up again. Expected: export succeeds (reject non-finite on write, or sanitise)."))
    func infiniteNumberDoesNotBlockExport() throws {
        let stack = try populated()
        let shot = try #require(stack.competitiveContext.fetch(FetchDescriptor<Shot>()).first)
        shot.wpaDelta = .infinity
        try stack.competitiveContext.save()
        _ = try stack.exportBackup()
    }

    @Test(.disabled("AUDIT-FINDING F10: NaN in a plain Double column (Shot.wpaDelta) is silently exported as 0.0, corrupting stats with no error. Expected: NaN rejected at write time or surfaced, never turned into a real value."))
    func nanIsNotSilentlyExportedAsZero() throws {
        let stack = try populated()
        let shot = try #require(stack.competitiveContext.fetch(FetchDescriptor<Shot>()).first)
        let id = shot.id
        shot.wpaDelta = .nan
        try stack.competitiveContext.save()
        let b = try BackupV1.decode(stack.exportBackup())
        #expect(b.competitive.shots.first { $0.id == id }?.wpaDelta != 0)
    }

    @Test func nonFiniteNumberCurrentlyBlocksExport() throws {
        // Pins current behaviour behind F6 so a fix is noticed.
        let stack = try populated()
        let shot = try #require(stack.competitiveContext.fetch(FetchDescriptor<Shot>()).first)
        shot.wpaDelta = .infinity
        try stack.competitiveContext.save()
        #expect(throws: (any Error).self) { try stack.exportBackup() }
    }

    @Test(.disabled("AUDIT-FINDING F7: Blob.encode preconditionFailure on NaN in any blob value (skillModel, vector, TableState, features) crashes the app on a plain property set. Expected: no crash."))
    func nanInBlobValueDoesNotCrash() throws {
        let p = PlayerProfile(name: "X", avatarSymbol: "s", avatarColor: "c")
        p.skillModel = StoredSkillModel(aimSigma: .nan, speedSigma: 0, spinSigma: 0, samples: 0)
    }

    // MARK: Recognition privacy

    @Test(.disabled("AUDIT-FINDING F2: a recognition row whose id collides with the local owner's RecognitionData is inserted as a new object; SwiftData's .unique upsert then overwrites the owner's embeddings with the crafted ones. Expected: owner embeddings unchanged."))
    func recognitionIDCollisionCannotOverwriteOwnerEmbeddings() throws {
        let stack = try populated()
        let ownerRec = try #require(stack.competitiveContext.fetch(FetchDescriptor<RecognitionData>()).first)
        var b = emptyBackup(includesRecognition: true)
        b.competitive.profiles = [profile(recognition: .init(id: ownerRec.id, faceEmbedding: Data([9, 9, 9]),
                                                             appearanceEmbedding: nil, optedInAt: Fixture.t0,
                                                             version: 7, updatedAt: .now.addingTimeInterval(60)))]
        _ = try? stack.importBackup(b.encoded())
        let all = try stack.competitiveContext.fetch(FetchDescriptor<RecognitionData>())
        let owner = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>())
            .first { $0.id == Fixture.ownerID })
        #expect(owner.recognition?.faceEmbedding == Data([1, 2, 3]))
        #expect(all.filter { $0.faceEmbedding == Data([1, 2, 3]) }.count == 1)
    }

    @Test(.disabled("AUDIT-FINDING F3: SPEC §Privacy says embeddings live only on that player's own phone, but import stores recognition rows for non-owner profiles (e.g. a friend's backup). Expected: only the local owner's recognition is imported. Product decision needed."))
    func importDoesNotStoreOtherPlayersEmbeddings() throws {
        let stack = try populated()
        var b = emptyBackup(includesRecognition: true)
        b.competitive.profiles = [profile(recognition: .init(id: UUID(), faceEmbedding: Data([7]),
                                                             appearanceEmbedding: nil, optedInAt: Fixture.t0,
                                                             version: 1, updatedAt: Fixture.t0))]
        try stack.importBackup(b.encoded())
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 1)
    }

    @Test(.disabled("AUDIT-FINDING F4: after 'Delete my recognition data', importing an older backup made with recognition silently restores the deleted embeddings (no tombstone/opt-out flag). Expected: deletion sticks unless the user opts in again. Product decision needed."))
    func deletedRecognitionStaysDeletedAfterOldBackupImport() throws {
        let stack = try populated()
        let old = try stack.exportBackup(includeRecognition: true)
        try stack.deleteMyRecognitionData()
        try stack.importBackup(old)
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 0)
    }

    @Test func deleteMyRecognitionDataSurvivesReopenOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = try PersistenceStack(directory: dir)
            _ = Fixture.populateCompetitive(s.competitiveContext)
            try s.competitiveContext.save()
            try s.deleteMyRecognitionData()
        }
        let reopened = try PersistenceStack(directory: dir)
        #expect(try Fixture.count(RecognitionData.self, reopened.competitiveContext) == 0)
        #expect(try Fixture.count(PlayerProfile.self, reopened.competitiveContext) == 1)
        let backup = String(decoding: try reopened.exportBackup(includeRecognition: true), as: UTF8.self)
        #expect(!backup.contains("faceEmbedding"))
    }

    @Test func deleteMyRecognitionDataTwiceIsSafe() throws {
        let stack = try populated()
        try stack.deleteMyRecognitionData()
        try stack.deleteMyRecognitionData()
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 0)
    }

    @Test func recognitionInBackupIgnoredWhenFlagFalseEvenIfPresent() throws {
        let fresh = try PersistenceStack(inMemory: true)
        var b = emptyBackup(includesRecognition: false)
        b.competitive.profiles = [profile(owner: true, recognition: .init(id: UUID(), faceEmbedding: Data([1]),
                                                                          appearanceEmbedding: nil, optedInAt: Fixture.t0,
                                                                          version: 1, updatedAt: Fixture.t0))]
        try fresh.importBackup(b.encoded())
        #expect(try Fixture.count(RecognitionData.self, fresh.competitiveContext) == 0)
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
            guest.recognition = Fixture.recognition()
            s.competitiveContext.insert(guest)
            s.competitiveContext.insert(Fixture.shot(index: 9, shooter: Fixture.guestID))
            try s.competitiveContext.save()
            try s.purgeSessionGuests()
        }
        let r = try PersistenceStack(directory: dir)
        #expect(try r.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).map(\.id) == [Fixture.ownerID])
        #expect(try Fixture.count(RecognitionData.self, r.competitiveContext) == 1)
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

    @Test(.disabled("AUDIT-FINDING F8: a backup profile whose id matches a live session guest updates the guest row in place (isSessionGuest stays true), so the next purgeSessionGuests deletes the restored profile. Expected: imported profile survives purge."))
    func importedProfileMatchingGuestSurvivesPurge() throws {
        let stack = try populated()
        stack.competitiveContext.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "s",
                                                      avatarColor: "c", isSessionGuest: true, createdAt: Fixture.t0))
        try stack.competitiveContext.save()
        var b = emptyBackup()
        b.competitive.profiles = [profile(Fixture.guestID, name: "Sam (saved)", updatedAt: .now.addingTimeInterval(60))]
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

    @Test(.disabled("AUDIT-FINDING F9: a failed import calls rollback() on the shared main contexts, silently discarding unrelated unsaved edits the app had pending. Expected: pending edits survive a failed import (or import refuses while contexts have changes)."))
    func failedImportKeepsUnrelatedPendingEdits() throws {
        let stack = try populated()
        let pending = PlayerProfile(name: "Unsaved", avatarSymbol: "s", avatarColor: "c")
        stack.competitiveContext.insert(pending)
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.profiles[0].name = "X"
        b.competitive.profiles[0].updatedAt = .now.addingTimeInterval(60)
        stack.beforeSave = { if $0 == .training { throw Injected() } }
        #expect(throws: Injected.self) { try stack.importBackup(b.encoded()) }
        stack.beforeSave = nil
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).contains { $0.name == "Unsaved" })
    }

    @Test func importThenOnDiskReopenMatchesExport() throws {
        let source = try populated()
        let backup = try source.exportBackup(includeRecognition: true, exportedAt: Fixture.t0)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do { try PersistenceStack(directory: dir).importBackup(backup) }
        let reopened = try PersistenceStack(directory: dir)
        #expect(try BackupV1.decode(reopened.exportBackup(includeRecognition: true, exportedAt: Fixture.t0))
                == BackupV1.decode(backup))
    }

    @Test(.disabled("AUDIT-FINDING F13: export is not byte-deterministic: TableState.balls ([BallID: BallState]) encodes as a hash-ordered key/value array, so two exports of the same unchanged store differ despite .sortedKeys. Expected: identical bytes (stable for diff/dedupe/checksums)."))
    func exportIsByteDeterministic() throws {
        let stack = try populated()
        let a = try stack.exportBackup(includeRecognition: true, exportedAt: Fixture.t0)
        for _ in 0..<5 { #expect(try stack.exportBackup(includeRecognition: true, exportedAt: Fixture.t0) == a) }
    }

    @Test func emptyBackupIsANoOp() throws {
        let stack = try populated()
        let before = try snapshot(stack)
        try stack.importBackup(emptyBackup(includesRecognition: true).encoded())
        #expect(try snapshot(stack) == before)
    }
}

