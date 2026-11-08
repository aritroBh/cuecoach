import CoreGraphics
import Foundation
import Geometry
import Observation
import Rules
import SwiftData
import UIKit

/// What Settings needs from persistence. Backed by `PersistenceStack` in the app (`PersistenceSettingsStore`)
/// and by in-memory fakes in previews and tests.
@MainActor public protocol SettingsStore: AnyObject {
    var hasRecognitionData: Bool { get }
    /// One tap: removes every template from the store in memory and keeps a short-lived in-memory snapshot.
    /// Nothing is written until `deleteMyRecognitionData` (commit) or `undoRecognitionDeletion`.
    func stageRecognitionDeletion() throws
    /// Puts the snapshot back. No-op when nothing is staged.
    func undoRecognitionDeletion() throws
    /// Commit: the delete reaches disk and the snapshot is dropped; gone for good.
    func deleteMyRecognitionData() throws
    /// Recognition templates are never exported (SPEC §2, D26).
    func exportBackup() throws -> Data
    func importBackup(_ data: Data) throws
}

/// Calibration owns the real one (D7, D12). `nil` until a LiDAR or ball-scale measurement exists.
public protocol TableMeasurementSource { var measured: TableSize? { get } }

public struct NoTableMeasurement: TableMeasurementSource {
    public init() {}
    public var measured: TableSize? { nil }
}

/// UserDefaults keys for the app-wide defaults set on this screen.
enum SettingsKeys {
    nonisolated static let ruleSet = "cc.rules.default"
    nonisolated static let threeBall = "cc.rules.threeBall"
    nonisolated static let tableSize = "cc.table.manual"
    nonisolated static let debugHUD = "cc.debug.hud"
    nonisolated static let recognitionOptIn = "cc.recognition.optIn"
}

/// Public so the Home owner can construct it; members stay internal (same app module).
@MainActor @Observable
public final class SettingsViewModel {
    /// `undoable`: deleted in one tap, Undo offered, commit pending. `deleted`: committed (transient).
    enum DeleteState: Equatable { case idle, undoable, deleted, failed }
    enum ExportState: Equatable { case idle, exporting, failed }
    enum ImportState: Equatable { case idle, importing, done }
    enum TableNote: Equatable { case autoMeasured, manual }
    enum ImportAlert: Equatable, Identifiable {
        case notABackup, newerVersion
        var id: Self { self }
        var message: String {
            switch self {
            case .notABackup: "This file isn't a CueCoach backup."
            case .newerVersion: "Made by a newer version."
            }
        }
    }

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let measurement: TableMeasurementSource
    @ObservationIgnored private let defaults: UserDefaults
    /// The one place export copies live. Emptied after sharing, before the next export, on launch, and when
    /// recognition data is deleted, so no stray copy of face data outlives "Delete" (SPEC §2).
    @ObservationIgnored private let exportDirectory: URL
    /// Identity owns the opt-in flow; Settings only reports that the user turned it on.
    @ObservationIgnored var onOptIn: (() -> Void)?
    @ObservationIgnored private let undoWindow: Duration
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var optInBeforeDelete = false
    /// A commit failed: the templates are still hidden (staged); tapping Delete again retries the commit.
    @ObservationIgnored private var commitFailed = false
    @ObservationIgnored nonisolated(unsafe) private var backgroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let notificationCenter: NotificationCenter

    private(set) var hasRecognitionData: Bool
    private(set) var deleteState: DeleteState = .idle
    private(set) var exportState: ExportState = .idle
    private(set) var importState: ImportState = .idle
    var importAlert: ImportAlert?

    var recognitionOptIn: Bool {
        didSet {
            defaults.set(recognitionOptIn, forKey: SettingsKeys.recognitionOptIn)
            if recognitionOptIn && !oldValue { onOptIn?() }
        }
    }
    var ruleSet: RuleSetID { didSet { defaults.set(ruleSet.rawValue, forKey: SettingsKeys.ruleSet) } }
    var threeBallRule: Bool { didSet { defaults.set(threeBallRule, forKey: SettingsKeys.threeBall) } }
    var debugHUD: Bool { didSet { defaults.set(debugHUD, forKey: SettingsKeys.debugHUD) } }
    private var manualTable: TableSize? {
        didSet { defaults.set(manualTable?.rawValue, forKey: SettingsKeys.tableSize) }
    }

    public nonisolated static let defaultExportDirectory = FileManager.default.temporaryDirectory.appending(path: "cc-export")

    public init(store: SettingsStore, measurement: TableMeasurementSource = NoTableMeasurement(),
                defaults: UserDefaults = .standard, exportDirectory: URL = SettingsViewModel.defaultExportDirectory,
                undoWindow: Duration = .seconds(5), notificationCenter: NotificationCenter = .default,
                announce: @escaping @MainActor (String) -> Void = SettingsViewModel.postAnnouncement) {
        self.store = store
        self.undoWindow = undoWindow
        self.announce = announce
        self.notificationCenter = notificationCenter
        self.measurement = measurement
        self.defaults = defaults
        self.exportDirectory = exportDirectory
        Self.removeExports(at: exportDirectory)   // a copy left by a share that never finished
        hasRecognitionData = store.hasRecognitionData
        recognitionOptIn = defaults.bool(forKey: SettingsKeys.recognitionOptIn)
        ruleSet = defaults.string(forKey: SettingsKeys.ruleSet).flatMap(RuleSetID.init(rawValue:)) ?? .default
        threeBallRule = defaults.object(forKey: SettingsKeys.threeBall) as? Bool ?? true
        debugHUD = defaults.bool(forKey: SettingsKeys.debugHUD)
        manualTable = defaults.string(forKey: SettingsKeys.tableSize).flatMap(TableSize.init(rawValue:))
        // Backgrounding closes the Undo window at once: a suspended app must not keep templates restorable.
        backgroundObserver = notificationCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitPendingDelete() }
        }
    }

    deinit {
        if let backgroundObserver { notificationCenter.removeObserver(backgroundObserver) }
    }

    public nonisolated static func postAnnouncement(_ text: String) {
        Task { @MainActor in UIAccessibility.post(notification: .announcement, argument: text) }
    }

    // MARK: Rules

    var showsThreeBallToggle: Bool { ruleSet == .wpaNine }

    nonisolated static func ruleShortLabel(_ r: RuleSetID) -> String {
        switch r { case .barEight: "Bar"; case .wpaEight: "WPA 8"; case .wpaNine: "WPA 9" }
    }
    nonisolated static func ruleLabel(_ r: RuleSetID) -> String {
        switch r { case .barEight: "8-ball bar rules"; case .wpaEight: "8-ball WPA"; case .wpaNine: "9-ball WPA" }
    }
    nonisolated static func ruleBall(_ r: RuleSetID) -> Int { r == .wpaNine ? 9 : 8 }

    // MARK: Table

    var tableSize: TableSize { manualTable ?? measurement.measured ?? .sevenFoot }

    var tableNote: TableNote? {
        guard measurement.measured != nil else { return nil }
        return manualTable == nil ? .autoMeasured : .manual
    }

    func selectTable(_ size: TableSize) { manualTable = size }

    /// Every table is 2:1. Fit the 9 ft table to `box`, then scale width and height together.
    nonisolated static func silhouetteRect(_ size: TableSize, in box: CGSize) -> CGRect {
        let fullW = min(box.width, box.height * 2)
        let s = silhouetteScale(size)
        let w = fullW * s, h = fullW / 2 * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// Width relative to a 9 ft table, from the true playing lengths.
    nonisolated static func silhouetteScale(_ size: TableSize) -> Double {
        size.playingLength / TableSize.nineFoot.playingLength
    }
    nonisolated static func feet(_ size: TableSize) -> Int {
        switch size { case .sevenFoot: 7; case .eightFoot: 8; case .nineFoot: 9 }
    }
    func tableAccessibilityLabel(_ size: TableSize) -> String {
        let base = "\(Self.feet(size)) foot table"
        return tableNote == .autoMeasured && size == tableSize ? base + ", measured" : base
    }

    // MARK: Privacy

    nonisolated static let deleteRowTitle = "Delete recognition data"
    nonisolated static let undoTitle = "Undo"
    nonisolated static let deletedAnnouncement = "Recognition data deleted, Undo available"

    var canDelete: Bool { deleteState != .undoable && (hasRecognitionData || commitFailed) }
    /// Export/Import tiles are usable unless a picked file is being read or just finished.
    var backupEnabled: Bool { importState == .idle && exportState != .exporting }

    /// One tap, no dialog (SPEC §2). The templates leave the store immediately (in memory), Undo is offered for
    /// `undoWindow`, then the delete is committed. Backgrounding or leaving Settings commits at once.
    func deleteTapped() {
        guard canDelete else { return }
        if commitFailed {
            deleteState = .undoable
            commitPendingDelete()
            return
        }
        do {
            try store.stageRecognitionDeletion()
        } catch {
            deleteState = .failed
            return
        }
        Self.removeExports(at: exportDirectory)
        optInBeforeDelete = recognitionOptIn
        hasRecognitionData = store.hasRecognitionData
        recognitionOptIn = false
        deleteState = .undoable
        announce(Self.deletedAnnouncement)
        undoTask?.cancel()
        let window = undoWindow
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.commitPendingDelete()
        }
    }

    /// Inside the window only; afterwards the snapshot is gone and this does nothing.
    func undoDelete() {
        guard deleteState == .undoable else { return }
        undoTask?.cancel()
        undoTask = nil
        do {
            try store.undoRecognitionDeletion()
            hasRecognitionData = store.hasRecognitionData
            recognitionOptIn = optInBeforeDelete
            deleteState = .idle
        } catch {
            commitPendingDelete()   // can't restore: never leave a half state, finish the delete
        }
    }

    /// Closes the Undo window: window expiry, app backgrounded, Settings left. Idempotent.
    func commitPendingDelete() {
        guard deleteState == .undoable else { return }
        undoTask?.cancel()
        undoTask = nil
        do {
            try store.deleteMyRecognitionData()
            commitFailed = false
            deleteState = .deleted
        } catch {
            commitFailed = true
            deleteState = .failed
        }
        hasRecognitionData = store.hasRecognitionData
    }

    /// Ends the transient "done" states (the view calls it ~1.5 s later).
    func settle() {
        if deleteState == .deleted { deleteState = .idle }
        if importState == .done { importState = .idle }
    }

    // MARK: Backup

    nonisolated static func backupFilename(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "CueCoach-%04d-%02d-%02d.json", c.year!, c.month!, c.day!)
    }

    /// Encodes on the main actor (SwiftData), writes the file off it. Returns nil on failure.
    func export(now: Date = .now) async -> URL? {
        exportState = .exporting
        await Task.yield()
        do {
            let data = try store.exportBackup()
            let name = Self.backupFilename(now)
            let dir = exportDirectory
            let url = try await Task.detached(priority: .userInitiated) {
                Self.removeExports(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appending(path: name)
                try data.write(to: url, options: .atomic)
                return url
            }.value
            exportState = .idle
            return url
        } catch {
            exportState = .failed
            return nil
        }
    }

    /// The share sheet closed (shared or cancelled): the temp copy is no longer needed.
    func shareFinished() { Self.removeExports(at: exportDirectory) }

    nonisolated static func removeExports(at dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Called only once the picker returns a URL. Opening the picker never changes state, because a
    /// cancelled `fileImporter` does not call back.
    func importFile(at url: URL) {
        importState = .importing
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url) { importBackup(data) } else { importFailedToRead() }
    }

    func importBackup(_ data: Data) {
        importState = .importing
        do {
            try store.importBackup(data)
            hasRecognitionData = store.hasRecognitionData
            importAlert = nil
            importState = .done
        } catch BackupError.unsupportedVersion {
            importAlert = .newerVersion
            importState = .idle
        } catch {
            importAlert = .notABackup
            importState = .idle
        }
    }

    func importFailedToRead() {
        importAlert = .notABackup
        importState = .idle
    }

    func importCancelled() { importState = .idle }
}

/// Production adapter over the shared persistence stack. Recognition lives in its own backup-excluded store; the
/// Undo window is the stack's staged delete (in-memory snapshot + pending-delete marker + galleries cleared).
@MainActor
final class PersistenceSettingsStore: SettingsStore {
    private let stack: PersistenceStack
    private var pending: RecognitionUndo?

    init(stack: PersistenceStack) { self.stack = stack }

    var hasRecognitionData: Bool { Self.recognitionPresent { [try stack.hasRecognitionData] } }

    /// Fails safe: if the store can't be read, assume data may exist so Delete stays available.
    nonisolated static func recognitionPresent(_ ownersHaveRecognition: () throws -> [Bool]) -> Bool {
        guard let flags = try? ownersHaveRecognition() else { return true }
        return flags.contains(true)
    }

    func stageRecognitionDeletion() throws {
        let undo = try stack.beginRecognitionDeletion()
        // A second tap inside the window keeps the first snapshot too.
        pending = RecognitionUndo(records: (pending?.records ?? []) + undo.records)
    }

    func undoRecognitionDeletion() throws {
        guard let undo = pending else { return }
        pending = nil
        try stack.undoRecognitionDeletion(undo)
    }

    func deleteMyRecognitionData() throws {
        pending = nil
        try stack.deleteMyRecognitionData()
    }

    func exportBackup() throws -> Data { try stack.exportBackup() }
    func importBackup(_ data: Data) throws { try stack.importBackup(data) }
}

enum SAFetch {
    nonisolated static func localOwners() -> FetchDescriptor<PlayerProfile> {
        FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner })
    }
}

/// In-memory store for previews and the debug router.
@MainActor
final class InMemorySettingsStore: SettingsStore {
    private var stored: Bool
    private var staged = false
    var failDelete = false
    var hasRecognitionData: Bool { stored && !staged }
    init(hasRecognitionData: Bool) { stored = hasRecognitionData }
    struct Failed: Error {}
    func stageRecognitionDeletion() throws {
        if failDelete { throw Failed() }
        staged = true
    }
    func undoRecognitionDeletion() throws { staged = false }
    func deleteMyRecognitionData() throws {
        if failDelete { throw Failed() }
        stored = false
        staged = false
    }
    func exportBackup() throws -> Data { Data("{\"version\":1}".utf8) }
    func importBackup(_ data: Data) throws { _ = try BackupV1.decode(data) }
}
