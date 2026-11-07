import Foundation
import Geometry
import Rules
import Testing
@testable import CueCoach

@MainActor
final class FakeSettingsStore: SettingsStore {
    var hasRecognitionData: Bool
    var deleteError: Error?
    var exportError: Error?
    var importError: Error?
    var deleteCalls = 0
    var exportedWith: [Bool] = []
    var imported: [Data] = []

    init(hasRecognitionData: Bool = true) { self.hasRecognitionData = hasRecognitionData }

    func deleteMyRecognitionData() throws {
        deleteCalls += 1
        if let deleteError { throw deleteError }
        hasRecognitionData = false
    }
    func exportBackup(includeRecognition: Bool) throws -> Data {
        exportedWith.append(includeRecognition)
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

    func model(store: FakeSettingsStore = .init(), measured: TableSize? = nil,
               defaults: UserDefaults? = nil) -> SettingsViewModel {
        SettingsViewModel(store: store, measurement: FixedMeasurement(measured: measured),
                          defaults: defaults ?? freshDefaults())
    }

    // MARK: defaults

    @Test func defaultsMatchSpec() {
        let m = model()
        #expect(m.recognitionOptIn == false)
        #expect(m.ruleSet == .barEight)
        #expect(m.threeBallRule == true)           // D13
        #expect(m.tableSize == .sevenFoot)         // D14
        #expect(m.debugHUD == false)
        #expect(m.includeFaceInExport == false)    // SCHEMA: never exported unless ticked
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

    @Test func accessibilityLabels() {
        let m = model(measured: .eightFoot)
        #expect(SettingsViewModel.ruleLabel(.barEight) == "8-ball bar rules")
        #expect(SettingsViewModel.ruleLabel(.wpaEight) == "8-ball WPA")
        #expect(SettingsViewModel.ruleLabel(.wpaNine) == "9-ball WPA")
        #expect(m.tableAccessibilityLabel(.sevenFoot) == "7 foot table")
        #expect(m.tableAccessibilityLabel(.eightFoot) == "8 foot table, measured")
    }

    @Test func shortLabelsAreAtMostTwoWords() {
        for r in RuleSetID.allCases {
            #expect(SettingsViewModel.ruleShortLabel(r).split(separator: " ").count <= 2)
        }
    }

    // MARK: privacy

    @Test func deleteClearsDataAndOptIn() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store)
        m.recognitionOptIn = true
        #expect(m.canDelete)
        m.confirmDelete()
        #expect(store.deleteCalls == 1)
        #expect(m.deleteState == .deleted)
        #expect(m.recognitionOptIn == false)
        #expect(m.hasRecognitionData == false)
        #expect(!m.canDelete)
    }

    @Test func deleteFailureKeepsRowEnabled() {
        let store = FakeSettingsStore(hasRecognitionData: true)
        store.deleteError = Boom()
        let m = model(store: store)
        m.recognitionOptIn = true
        m.confirmDelete()
        #expect(m.deleteState == .failed)
        #expect(m.canDelete)
        #expect(m.recognitionOptIn == true)
    }

    @Test func nothingStoredDisablesDelete() {
        let m = model(store: .init(hasRecognitionData: false))
        #expect(!m.canDelete)
        #expect(!m.showsIncludeFaceToggle)
    }

    @Test func deletedStateSettlesBackToIdle() {
        let m = model()
        m.confirmDelete()
        m.settle()
        #expect(m.deleteState == .idle)
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

    @Test func exportWritesDatedFileAndHonoursFaceToggle() throws {
        let store = FakeSettingsStore(hasRecognitionData: true)
        let m = model(store: store)
        let date = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let url = try #require(m.export(now: date))
        #expect(url.lastPathComponent == "CueCoach-2026-11-06.json")
        #expect(try Data(contentsOf: url) == Data("{\"version\":1}".utf8))
        m.includeFaceInExport = true
        _ = m.export(now: date)
        #expect(store.exportedWith == [false, true])
        #expect(m.exportState == .idle)
    }

    @Test func faceToggleIgnoredWhenNoRecognitionData() {
        let store = FakeSettingsStore(hasRecognitionData: false)
        let m = model(store: store)
        m.includeFaceInExport = true
        _ = m.export(now: .now)
        #expect(store.exportedWith == [false])
    }

    @Test func exportFailureShowsInlineError() {
        let store = FakeSettingsStore()
        store.exportError = Boom()
        let m = model(store: store)
        #expect(m.export(now: .now) == nil)
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

    @Test func importRefreshesRecognitionPresence() {
        let store = FakeSettingsStore(hasRecognitionData: false)
        let m = model(store: store)
        store.hasRecognitionData = true
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
        let store = PersistenceSettingsStore(stack: stack)
        #expect(store.hasRecognitionData)
        try store.deleteMyRecognitionData()
        #expect(!store.hasRecognitionData)
    }

    @Test func exportImportRoundTrip() throws {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        try stack.competitiveContext.save()
        let data = try PersistenceSettingsStore(stack: stack).exportBackup(includeRecognition: false)
        let other = try PersistenceStack(inMemory: true)
        try PersistenceSettingsStore(stack: other).importBackup(data)
        #expect(try Fixture.count(Session.self, other.competitiveContext) == 1)
    }
}
