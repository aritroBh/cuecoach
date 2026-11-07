import CoreGraphics
import Foundation
import Geometry
import Observation
import Rules
import SwiftData

/// What Settings needs from persistence. Backed by `PersistenceStack` in the app (`PersistenceSettingsStore`)
/// and by in-memory fakes in previews and tests.
@MainActor public protocol SettingsStore: AnyObject {
    var hasRecognitionData: Bool { get }
    func deleteMyRecognitionData() throws
    func exportBackup(includeRecognition: Bool) throws -> Data
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
    enum DeleteState: Equatable { case idle, deleting, deleted, failed }
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
    /// Identity owns the opt-in flow; Settings only reports that the user turned it on.
    @ObservationIgnored var onOptIn: (() -> Void)?

    private(set) var hasRecognitionData: Bool
    private(set) var deleteState: DeleteState = .idle
    private(set) var exportState: ExportState = .idle
    private(set) var importState: ImportState = .idle
    var importAlert: ImportAlert?
    var includeFaceInExport = false

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

    public init(store: SettingsStore, measurement: TableMeasurementSource = NoTableMeasurement(),
                defaults: UserDefaults = .standard) {
        self.store = store
        self.measurement = measurement
        self.defaults = defaults
        hasRecognitionData = store.hasRecognitionData
        recognitionOptIn = defaults.bool(forKey: SettingsKeys.recognitionOptIn)
        ruleSet = defaults.string(forKey: SettingsKeys.ruleSet).flatMap(RuleSetID.init(rawValue:)) ?? .default
        threeBallRule = defaults.object(forKey: SettingsKeys.threeBall) as? Bool ?? true
        debugHUD = defaults.bool(forKey: SettingsKeys.debugHUD)
        manualTable = defaults.string(forKey: SettingsKeys.tableSize).flatMap(TableSize.init(rawValue:))
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
    nonisolated static let deleteDialogTitle = "Delete recognition data?"

    var canDelete: Bool { hasRecognitionData && deleteState != .deleting }
    /// Export/Import tiles are usable unless a picked file is being read or just finished.
    var backupEnabled: Bool { importState == .idle && exportState != .exporting }
    var showsIncludeFaceToggle: Bool { hasRecognitionData }

    /// SwiftData contexts are main-actor bound, so the store call stays here; the yield lets the
    /// spinner render before the (synchronous) delete runs.
    func confirmDelete() async {
        deleteState = .deleting
        await Task.yield()
        do {
            try store.deleteMyRecognitionData()
            hasRecognitionData = store.hasRecognitionData
            recognitionOptIn = false
            includeFaceInExport = false
            deleteState = .deleted
        } catch {
            deleteState = .failed
        }
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
            let data = try store.exportBackup(includeRecognition: includeFaceInExport && hasRecognitionData)
            let name = Self.backupFilename(now)
            let url = try await Task.detached(priority: .userInitiated) {
                let dir = FileManager.default.temporaryDirectory.appending(path: "cc-export-\(UUID().uuidString)")
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

/// Production adapter over the shared persistence stack (read-only use of its public API).
@MainActor
final class PersistenceSettingsStore: SettingsStore {
    private let stack: PersistenceStack
    init(stack: PersistenceStack) { self.stack = stack }

    var hasRecognitionData: Bool {
        let owners = (try? stack.competitiveContext.fetch(
            SAFetch.localOwners())) ?? []
        return owners.contains { $0.recognition != nil }
    }
    func deleteMyRecognitionData() throws { try stack.deleteMyRecognitionData() }
    func exportBackup(includeRecognition: Bool) throws -> Data {
        try stack.exportBackup(includeRecognition: includeRecognition)
    }
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
    var hasRecognitionData: Bool
    var failDelete = false
    init(hasRecognitionData: Bool) { self.hasRecognitionData = hasRecognitionData }
    func deleteMyRecognitionData() throws {
        struct Failed: Error {}
        if failDelete { throw Failed() }
        hasRecognitionData = false
    }
    func exportBackup(includeRecognition: Bool) throws -> Data { Data("{\"version\":1}".utf8) }
    func importBackup(_ data: Data) throws { _ = try BackupV1.decode(data) }
}
