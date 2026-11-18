import Foundation
import Geometry
import Rules
import SwiftData
import Testing
import UIKit
@testable import CueCoach

@MainActor
final class FakeSettingsStore: SettingsStore {
    /// What is "on disk": only a commit changes it.
    var committedData: Bool
    /// Removed in memory, waiting for the Undo window to close.
    var staged = false
    var hasRecognitionData: Bool { committedData && !staged }
    var stageError: Error?
    var deleteError: Error?
    var exportError: Error?
    var importError: Error?
    var stageCalls = 0
    var undoCalls = 0
    var deleteCalls = 0
    var exportCalls = 0
    var imported: [Data] = []
    var onExport: (() -> Void)?

    init(hasRecognitionData: Bool = true) { committedData = hasRecognitionData }

    func stageRecognitionDeletion() throws {
        stageCalls += 1
        if let stageError { throw stageError }
        staged = true
    }
    func undoRecognitionDeletion() throws {
        undoCalls += 1
        staged = false
    }
    func deleteMyRecognitionData() throws {
        deleteCalls += 1
        if let deleteError { throw deleteError }
        committedData = false
        staged = false
    }
    func exportBackup() throws -> Data {
        exportCalls += 1
        onExport?()
        if let exportError { throw exportError }
        return Data("{\"version\":1}".utf8)
    }
    func importBackup(_ data: Data) throws {
        if let importError { throw importError }
        imported.append(data)
    }
}

struct FixedMeasurement: TableMeasurementSource { var measured: TableSize? }
struct Boom: Error {}

@MainActor
@Suite struct SettingsViewModelTests {
    func freshDefaults() -> UserDefaults {
        let name = "cc.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func freshExportDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cc-tests-export-\(UUID().uuidString)")
    }

    func model(store: FakeSettingsStore = .init(), measured: TableSize? = nil,
               defaults: UserDefaults? = nil, exportDirectory: URL? = nil,
               undoWindow: Duration = .seconds(60), center: NotificationCenter = NotificationCenter(),
               announcements: Announcements? = nil) -> SettingsViewModel {
        let sink = announcements ?? Announcements()
        return SettingsViewModel(store: store, measurement: FixedMeasurement(measured: measured),
                                 defaults: defaults ?? freshDefaults(), exportDirectory: exportDirectory ?? freshExportDir(),
                                 undoWindow: undoWindow, notificationCenter: center,
                                 announce: { sink.said.append($0) })
    }

    @MainActor final class Announcements { var said: [String] = [] }

    // MARK: defaults

    @Test func defaultsMatchSpec() {
        let m = model()
        #expect(m.recognitionOptIn == false)
        #expect(m.ruleSet == .barEight)
        #expect(m.threeBallRule == true)           // D13
        #expect(m.tableSize == .sevenFoot)         // D14
        #expect(m.debugHUD == false)
    }

    @Test func settingsPersistAcrossInstances() {
        let d = freshDefaults()
        let a = model(defaults: d)
        a.ruleSet = .wpaNine
        a.threeBallRule = false
        a.selectTable(.nineFoot)
        a.debugHUD = true
        a.recognitionOptIn = true
        let b = model(defaults: d)
        #expect(b.ruleSet == .wpaNine)
        #expect(b.threeBallRule == false)
        #expect(b.tableSize == .nineFoot)
        #expect(b.debugHUD == true)
        #expect(b.recognitionOptIn == true)
    }

    // Fix round (review finding 5): the switch writes the key LiveScreen reads (`dev.hud`).
    @Test func debugHUDWritesTheKeyLiveReads() {
        let d = freshDefaults()
        let m = model(defaults: d)
        m.debugHUD = true
        #expect(d.bool(forKey: "dev.hud"))
        m.debugHUD = false
        #expect(d.object(forKey: "dev.hud") == nil)
    }

    @Test func oldDebugHUDValueMigratesOnce() {
        let d = freshDefaults()
        d.set(true, forKey: "cc.debug.hud")
        let m = model(defaults: d)
        #expect(m.debugHUD)
        #expect(d.bool(forKey: "dev.hud"))
        #expect(d.object(forKey: "cc.debug.hud") == nil)
        m.debugHUD = false
        #expect(!model(defaults: d).debugHUD)     // the old key can't resurrect it
    }

    @Test func threeBallToggleOnlyForWPANine() {
        let m = model()
        #expect(!m.showsThreeBallToggle)
        m.ruleSet = .wpaEight
        #expect(!m.showsThreeBallToggle)
        m.ruleSet = .wpaNine
        #expect(m.showsThreeBallToggle)
    }

    // MARK: table

    @Test func noMeasurementMeansNoNote() {
        let m = model()
        #expect(m.tableNote == nil)
        #expect(m.tableSize == .sevenFoot)
    }

    @Test func measurementWinsUntilManualOverride() {
        let m = model(measured: .eightFoot)
        #expect(m.tableSize == .eightFoot)
        #expect(m.tableNote == .autoMeasured)
        m.selectTable(.nineFoot)
        #expect(m.tableSize == .nineFoot)
        #expect(m.tableNote == .manual)
    }

    @Test func manualPickWithoutMeasurementShowsNoNote() {
        let m = model()
        m.selectTable(.eightFoot)
        #expect(m.tableNote == nil)
    }

    @Test func tableSilhouetteWidthsAreTrueProportion() {
        let w7 = SettingsViewModel.silhouetteScale(.sevenFoot)
        let w9 = SettingsViewModel.silhouetteScale(.nineFoot)
        #expect(w9 == 1)
        #expect(abs(w7 - 80.0 / 100.0) < 0.0001)
        #expect(SettingsViewModel.silhouetteScale(.eightFoot) > w7)
    }

    @Test func silhouettesKeepTwoToOneAndScaleTogether() {
        let box = CGSize(width: 100, height: 44)
        let r9 = SettingsViewModel.silhouetteRect(.nineFoot, in: box)
        for size in TableSize.allCases {
            let r = SettingsViewModel.silhouetteRect(size, in: box)
            #expect(abs(r.width / r.height - 2) < 0.0001, "\(size)")
            #expect(abs(r.width / r9.width - SettingsViewModel.silhouetteScale(size)) < 0.0001)
            #expect(r.height <= box.height && r.width <= box.width)
            #expect(abs(r.midX - box.width / 2) < 0.0001 && abs(r.midY - box.height / 2) < 0.0001)
        }
        #expect(SettingsViewModel.silhouetteRect(.sevenFoot, in: box).height
                < SettingsViewModel.silhouetteRect(.eightFoot, in: box).height)
    }

    @Test func deleteRowCopy() {
        #expect(SettingsViewModel.deleteRowTitle == "Delete recognition data")
        #expect(SettingsViewModel.undoTitle == "Undo")
        #expect(SettingsViewModel.deletedAnnouncement == "Recognition data deleted, Undo available")
    }

    @Test func accessibilityLabels() {
        let m = model(measured: .eightFoot)
        #expect(SettingsViewModel.ruleLabel(.barEight) == "8-ball bar rules")
        #expect(SettingsViewModel.ruleLabel(.wpaEight) == "8-ball WPA")
        #expect(SettingsViewModel.ruleLabel(.wpaNine) == "9-ball WPA")
        #expect(m.tableAccessibilityLabel(.sevenFoot) == "7 foot table")
        #expect(m.tableAccessibilityLabel(.eightFoot) == "8 foot table, measured")
    }

    /// D46: five sizes in length order; Pro 8 and 86″ are named, not rounded to feet.
    @Test func tableLabelsCoverTheFivePresets() {
        let m = model(measured: .proEight)
        #expect(TableSize.allCases.map(SettingsViewModel.tableShortLabel) == ["7 ft", "86″", "Pro 8", "8 ft", "9 ft"])
        #expect(TableSize.allCases.map(SettingsViewModel.tableSpokenLabel)
                == ["7 foot", "86 inch", "Pro 8", "8 foot", "9 foot"])
        #expect(m.tableAccessibilityLabel(.eightySixInch) == "86 inch table")
        #expect(m.tableAccessibilityLabel(.proEight) == "Pro 8 table, measured")
        let box = CGSize(width: 100, height: 44)
        let widths = TableSize.allCases.map { SettingsViewModel.silhouetteRect($0, in: box).width }
        #expect(widths == widths.sorted() && Set(widths).count == 5)
    }

    @Test func shortLabelsAreAtMostTwoWords() {
        for r in RuleSetID.allCases {
            #expect(SettingsViewModel.ruleShortLabel(r).split(separator: " ").count <= 2)
        }
    }

    // MARK: privacy

    // One tap (SPEC §2): no dialog step. The data leaves the store at once; the commit waits for the window.
    @Test func oneTapRemovesDataAndOffersUndo() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let said = Announcements()
        let m = model(store: store, announcements: said)
        m.recognitionOptIn = true
        #expect(m.canDelete)
        m.deleteTapped()
        #expect(store.stageCalls == 1)
        #expect(!store.hasRecognitionData)
        #expect(store.deleteCalls == 0)              // nothing committed while Undo is offered
        #expect(m.deleteState == .undoable)
        #expect(m.hasRecognitionData == false)
        #expect(m.recognitionOptIn == false)
        #expect(!m.canDelete)
        #expect(said.said == ["Recognition data deleted, Undo available"])
    }

    @Test func undoRestoresDataAndOptIn() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store)
        m.recognitionOptIn = true
        m.deleteTapped()
        m.undoDelete()
        #expect(store.undoCalls == 1)
        #expect(store.deleteCalls == 0)
        #expect(store.hasRecognitionData)
        #expect(m.hasRecognitionData)
        #expect(m.recognitionOptIn)
        #expect(m.deleteState == .idle)
    }

    @Test func windowClosingCommitsTheDelete() async throws {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store, undoWindow: .milliseconds(50))
        m.deleteTapped()
        for _ in 0..<100 where store.deleteCalls == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.deleteCalls == 1)
        #expect(!store.committedData)
        #expect(m.deleteState == .deleted)
        m.undoDelete()                                // too late: gone for good
        #expect(store.undoCalls == 0)
        #expect(!store.committedData)
    }

    @Test func backgroundingCommitsImmediately() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let center = NotificationCenter()
        let m = model(store: store, center: center)
        m.deleteTapped()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(store.deleteCalls == 1)
        #expect(!store.committedData)
        #expect(m.deleteState == .deleted)
        m.undoDelete()
        #expect(store.undoCalls == 0)
    }

    @Test func backgroundingWithoutPendingDeleteDoesNothing() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let center = NotificationCenter()
        _ = model(store: store, center: center)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(store.deleteCalls == 0)
        #expect(store.committedData)
    }

    @Test func leavingSettingsCommits() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store)
        m.deleteTapped()
        m.commitPendingDelete()
        #expect(store.deleteCalls == 1)
        m.commitPendingDelete()
        #expect(store.deleteCalls == 1)              // idempotent
    }

    @Test func stageFailureKeepsRowEnabled() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        store.stageError = Boom()
        let m = model(store: store)
        m.recognitionOptIn = true
        m.deleteTapped()
        #expect(m.deleteState == .failed)
        #expect(m.canDelete)
        #expect(m.recognitionOptIn == true)
    }

    @Test func commitFailureShowsErrorAndAllowsRetry() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        store.deleteError = Boom()
        let m = model(store: store)
        m.deleteTapped()
        m.commitPendingDelete()
        #expect(m.deleteState == .failed)
        store.deleteError = nil
        m.deleteTapped()
        m.commitPendingDelete()
        #expect(m.deleteState == .deleted)
        #expect(!store.committedData)
    }

    @Test func nothingStoredDisablesDelete() {
        let m = model(store: .init(hasRecognitionData: false))
        #expect(!m.canDelete)
    }

    @Test func deletedStateSettlesBackToIdle() {
        let m = model()
        m.deleteTapped()
        m.commitPendingDelete()
        m.settle()
        #expect(m.deleteState == .idle)
    }

    /// The production adapter: one tap stages the delete in the recognition store (unsaved, galleries cleared),
    /// Undo puts the same templates back, and the commit empties the store.
    @Test func persistenceStoreStagesUndoesAndCommits() throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = PlayerProfile(name: "Ari", avatarSymbol: "s", avatarColor: "c", isLocalOwner: true)
        stack.competitiveContext.insert(owner)
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: owner.id, faceEmbedding: Data([1, 2, 3]), appearanceEmbedding: Data([4]),
                                   optedInAt: .now, version: 2)
        let store = PersistenceSettingsStore(stack: stack)
        #expect(store.hasRecognitionData)

        try store.stageRecognitionDeletion()
        #expect(!store.hasRecognitionData)
        #expect(try stack.recognition(for: owner.id) == nil)
        // Nothing reached the persistent store yet.
        #expect(try ModelContext(stack.recognitionContainer).fetchCount(FetchDescriptor<RecognitionData>()) == 1)

        try store.undoRecognitionDeletion()
        #expect(store.hasRecognitionData)
        let back = try #require(try stack.recognition(for: owner.id))
        #expect(back.faceEmbedding == Data([1, 2, 3]))
        #expect(back.appearanceEmbedding == Data([4]))
        #expect(back.version == 2)

        try store.stageRecognitionDeletion()
        try store.deleteMyRecognitionData()
        #expect(!store.hasRecognitionData)
        #expect(try ModelContext(stack.recognitionContainer).fetchCount(FetchDescriptor<RecognitionData>()) == 0)
    }

    /// A second tap inside the Undo window must not lose the first snapshot (Undo restores everything).
    @Test func persistenceStoreUndoAfterRepeatedStageRestores() throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = PlayerProfile(name: "Ari", avatarSymbol: "s", avatarColor: "c", isLocalOwner: true)
        stack.competitiveContext.insert(owner)
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: owner.id, faceEmbedding: Data([9]), appearanceEmbedding: nil,
                                   optedInAt: .now, version: 1)
        let store = PersistenceSettingsStore(stack: stack)
        try store.stageRecognitionDeletion()
        try store.stageRecognitionDeletion()
        try store.undoRecognitionDeletion()
        #expect(try stack.recognition(for: owner.id)?.faceEmbedding == Data([9]))
    }

    @Test func turningToggleOffDoesNotDelete() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store)
        m.recognitionOptIn = true
        m.recognitionOptIn = false
        #expect(store.deleteCalls == 0)
        #expect(m.hasRecognitionData)
    }

    @Test func optInCallsIdentityHook() {
        let m = model()
        var calls = 0
        m.onOptIn = { calls += 1 }
        m.recognitionOptIn = true
        m.recognitionOptIn = false
        #expect(calls == 1)
    }

    // MARK: backup

    @Test func exportWritesDatedFile() async throws {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store)
        let date = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let url = try #require(await m.export(now: date))
        #expect(url.lastPathComponent == "CueCoach-2026-11-06.json")
        #expect(try Data(contentsOf: url) == Data("{\"version\":1}".utf8))
        #expect(store.exportCalls == 1)
        #expect(m.exportState == .idle)
    }

    // MARK: export copies (C4)

    @Test func exportsLiveInTheOneExportDirectory() async throws {
        let dir = freshExportDir()
        let m = model(exportDirectory: dir)
        let url = try #require(await m.export(now: .now))
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func deletingRecognitionRemovesExportedCopies() async throws {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let dir = freshExportDir()
        let m = model(store: store, exportDirectory: dir)
        let url = try #require(await m.export(now: .now))
        #expect(FileManager.default.fileExists(atPath: url.path))
        m.deleteTapped()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func finishingShareRemovesExport() async throws {
        let dir = freshExportDir()
        let m = model(exportDirectory: dir)
        let url = try #require(await m.export(now: .now))
        m.shareFinished()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func newExportReplacesTheOldCopy() async throws {
        let dir = freshExportDir()
        let m = model(exportDirectory: dir)
        let fmt = ISO8601DateFormatter()
        let first = try #require(await m.export(now: fmt.date(from: "2026-11-05T12:00:00Z")!))
        let second = try #require(await m.export(now: fmt.date(from: "2026-11-06T12:00:00Z")!))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["CueCoach-2026-11-06.json"])
    }

    @Test func staleExportsAreSweptOnLaunch() throws {
        let dir = freshExportDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "CueCoach-2026-01-01.json"))
        _ = model(exportDirectory: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func exportFailureShowsInlineError() async {
        let store = FakeSettingsStore()
        store.exportError = Boom()
        let m = model(store: store)
        let url = await m.export(now: .now)
        #expect(url == nil)
        #expect(m.exportState == .failed)
    }

    @Test func importSuccess() {
        let store = FakeSettingsStore()
        let m = model(store: store)
        m.importBackup(Data("x".utf8))
        #expect(store.imported.count == 1)
        #expect(m.importState == .done)
        #expect(m.importAlert == nil)
    }

    @Test func importErrorsMapToOneSentence() {
        let store = FakeSettingsStore()
        let m = model(store: store)
        store.importError = BackupError.unsupportedVersion(2)
        m.importBackup(Data())
        #expect(m.importAlert == .newerVersion)
        #expect(m.importAlert?.message == "Made by a newer version.")
        store.importError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        m.importBackup(Data())
        #expect(m.importAlert == .notABackup)
        #expect(m.importAlert?.message == "This file isn't a CueCoach backup.")
        store.importError = BackupError.missingParent(child: "Game", childID: UUID(), parentID: UUID())
        m.importBackup(Data())
        #expect(m.importAlert == .notABackup)
        #expect(m.importState == .idle)
    }

    @Test func exportShowsSpinnerStateWhileWorking() async {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store)
        var seen: [SettingsViewModel.ExportState] = []
        store.onExport = { seen.append(m.exportState) }
        _ = await m.export(now: .now)
        #expect(seen == [.exporting])
        #expect(m.exportState == .idle)
    }

    @Test func importStaysIdleUntilAFileIsPicked() {
        // Opening the picker must not lock Backup: a cancelled picker never reports back.
        let m = model()
        #expect(m.importState == .idle)
        #expect(m.backupEnabled)
        m.importCancelled()
        #expect(m.importState == .idle)
        #expect(m.backupEnabled)
    }

    @Test func importFileReadsPickedURL() throws {
        let store = FakeSettingsStore()
        let m = model(store: store)
        let url = FileManager.default.temporaryDirectory.appending(path: "cc-import-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        m.importFile(at: url)
        #expect(store.imported == [Data("{}".utf8)])
        #expect(m.importState == .done)
        #expect(!m.backupEnabled)
        m.settle()
        #expect(m.backupEnabled)
    }

    @Test func importFileUnreadableShowsAlertAndUnlocks() {
        let m = model()
        m.importFile(at: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"))
        #expect(m.importAlert == .notABackup)
        #expect(m.importState == .idle)
        #expect(m.backupEnabled)
    }

    @Test func importRefreshesRecognitionPresence() {
        let store = FakeSettingsStore(hasRecognitionData: false)
        let m = model(store: store)
        store.committedData = true
        m.importBackup(Data())
        #expect(m.hasRecognitionData)
    }
}

@MainActor
@Suite struct PersistenceSettingsStoreTests {
    @Test func reflectsAndDeletesOwnerRecognition() throws {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: Fixture.ownerID, faceEmbedding: Data([1]), appearanceEmbedding: nil,
                                   optedInAt: .now, version: 1)
        let store = PersistenceSettingsStore(stack: stack)
        #expect(store.hasRecognitionData)
        try store.deleteMyRecognitionData()
        #expect(!store.hasRecognitionData)
    }

    /// C3: a failed fetch must not claim "Nothing stored" and lock the delete button.
    @Test func recognitionProbeFailsSafeWhenFetchThrows() {
        #expect(PersistenceSettingsStore.recognitionPresent { throw Boom() } == true)
        #expect(PersistenceSettingsStore.recognitionPresent { [false, true] } == true)
        #expect(PersistenceSettingsStore.recognitionPresent { [false] } == false)
        #expect(PersistenceSettingsStore.recognitionPresent { [] } == false)
    }

    @Test func exportImportRoundTrip() throws {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        try stack.competitiveContext.save()
        let data = try PersistenceSettingsStore(stack: stack).exportBackup()
        let other = try PersistenceStack(inMemory: true)
        try PersistenceSettingsStore(stack: other).importBackup(data)
        #expect(try Fixture.count(Session.self, other.competitiveContext) == 1)
    }
}
