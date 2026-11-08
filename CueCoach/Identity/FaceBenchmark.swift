import Foundation

// F6 ship gate: face matching turns on only after an on-device, consented benchmark passes for that exact model.
// Volunteers give a separate "Help test face recognition" consent; their aligned crops are embedded and dropped
// at once, the embeddings live in RAM only for the run, and only aggregate numbers (no vectors, no subjects)
// are ever kept. Nothing here leaves the phone or is committed (face-embedding.md §6).

enum FaceBenchmark {
    static let far = 1e-3
    /// Proposed operating point (face-embedding.md §6.5); the user confirms the target before release.
    static let requiredTAR = 0.90
    static let minSubjects = 10
    /// FAR 1e-3 needs ≥ 3 / FAR impostor pairs to rest on a few false accepts rather than none.
    static let minImpostorPairs = 3_000

    struct Operating: Hashable, Sendable { var threshold: Double; var tar: Double }

    /// Accept ⇔ cosine > threshold. The threshold lets at most ⌊far·n⌋ impostors through. nil when the impostor
    /// count cannot resolve `far` at all.
    static func tarAtFAR(genuine: [Double], impostor: [Double], far: Double) -> Operating? {
        guard !genuine.isEmpty, Double(impostor.count) * far >= 1 else { return nil }
        let imp = impostor.sorted(by: >)
        let k = Int((far * Double(imp.count)).rounded(.down))
        let threshold = imp[min(k, imp.count - 1)]
        let tar = Double(genuine.filter { $0 > threshold }.count) / Double(genuine.count)
        return Operating(threshold: threshold, tar: tar)
    }

    enum Verdict: Hashable, Sendable {
        case pass(FaceShipGateRecord)
        case fail(tar: Double)
        case insufficientData
    }

    /// Per-subject embedding sets (same model) → verdict. Genuine = pairs within a subject, impostor = across.
    static func evaluate(subjects: [[Embedding]], modelID: String, now: Date = .now) -> Verdict {
        let sets = subjects.map { $0.filter { $0.modelID == modelID } }.filter { $0.count >= 2 }
        guard sets.count >= minSubjects else { return .insufficientData }
        var genuine: [Double] = [], impostor: [Double] = []
        for (i, s) in sets.enumerated() {
            for a in s.indices { for b in s.indices where b > a { if let c = s[a].cosine(s[b]) { genuine.append(c) } } }
            for t in sets[(i + 1)...] { for x in s { for y in t { if let c = x.cosine(y) { impostor.append(c) } } } }
        }
        guard impostor.count >= minImpostorPairs, let op = tarAtFAR(genuine: genuine, impostor: impostor, far: far)
        else { return .insufficientData }
        guard op.tar >= requiredTAR else { return .fail(tar: op.tar) }
        return .pass(FaceShipGateRecord(modelID: modelID, threshold: op.threshold, tar: op.tar, far: far,
                                        subjectCount: sets.count, passedAt: now))
    }
}

/// What a passed benchmark leaves behind: aggregates only.
struct FaceShipGateRecord: Codable, Hashable, Sendable {
    var modelID: String
    var threshold: Double
    var tar: Double
    var far: Double
    var subjectCount: Int
    var passedAt: Date

    /// Calibration earned by the benchmark: decision point at the FAR threshold, lookalike rate = the FAR.
    var cueModel: CueModel {
        CueModel(calibration: .init(threshold: threshold, slope: 25), lookalikeRate: far, lrRange: 0.01...100)
    }

    static func testPass(modelID: String) -> FaceShipGateRecord {
        FaceShipGateRecord(modelID: modelID, threshold: 0.4, tar: 0.95, far: 1e-3, subjectCount: 12,
                           passedAt: Date(timeIntervalSince1970: 0))
    }
}

/// Persists the gate record (aggregate numbers only) on this phone.
struct FaceShipGateStore: Sendable {
    var key = "identity.faceShipGate.v1"

    func load() -> FaceShipGateRecord? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(FaceShipGateRecord.self, from: $0) }
    }

    func save(_ r: FaceShipGateRecord) throws { UserDefaults.standard.set(try JSONEncoder().encode(r), forKey: key) }
    func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// The benchmark run: consented volunteers' face embeddings in RAM, keyed by an anonymous code.
@MainActor
final class FaceBenchmarkSession {
    let modelID: String
    private var subjects: [UUID: [Embedding]] = [:]

    init(modelID: String) { self.modelID = modelID }

    /// Adds one volunteer's embeddings (from N aligned crops at registration). Returns their anonymous code.
    @discardableResult
    func addSubject(_ embeddings: [Embedding]) -> UUID {
        let code = UUID()
        subjects[code] = embeddings.filter { $0.modelID == modelID }.compactMap(\.normalised)
        return code
    }

    /// Withdrawal: that volunteer's embeddings are gone now (and so is anything computed from them, since results
    /// are only computed on demand).
    func withdraw(_ code: UUID) { subjects[code] = nil }
    func deleteAll() { subjects = [:] }

    var subjectCount: Int { subjects.count }
    var embeddingCount: Int { subjects.values.reduce(0) { $0 + $1.count } }

    /// Evaluates, stores the aggregate record on a pass, and deletes every embedding either way (run over).
    func finish(store: FaceShipGateStore = FaceShipGateStore()) -> FaceBenchmark.Verdict {
        let v = FaceBenchmark.evaluate(subjects: Array(subjects.values), modelID: modelID)
        if case .pass(let r) = v { try? store.save(r) }
        deleteAll()
        return v
    }
}
