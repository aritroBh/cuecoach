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


    /// Open-set gate (face-embedding.md §6.4.2): held-out (non-enrolled) volunteers' probes accepted as *any*
    /// enrolled volunteer (FPIR), and enrolled probes accepted as the *wrong* one. Proposed targets; user confirms.
    static let maxFPIR = 0.005
    static let folds = 3

    enum Verdict: Hashable, Sendable {
        case pass(FaceShipGateRecord)
        case fail(tar: Double, fpir: Double, misidentifications: Int)
        case insufficientData
    }

    struct Probe { var subject: Int; var enrolled: Bool; var best: (subject: Int, score: Double)? }

    /// Rotating folds: fold f holds out every `folds`-th volunteer (≈ 1/3) as non-enrolled. Enrolled volunteers
    /// enrol with the first half of their embeddings and probe with the rest; held-out volunteers only probe.
    /// Each probe keeps its top-1 enrolled match.
    static func openSetProbes(_ sets: [[Embedding]]) -> [Probe] {
        var out: [Probe] = []
        for f in 0..<folds {
            var gallery: [Int: [Embedding]] = [:]
            var probes: [(Int, Bool, Embedding)] = []
            for (i, s) in sets.enumerated() {
                if i % folds == f { probes += s.map { (i, false, $0) } } else {
                    let half = s.count / 2
                    gallery[i] = Array(s.prefix(half))
                    probes += s.dropFirst(half).map { (i, true, $0) }
                }
            }
            for (subject, enrolled, e) in probes {
                let best = gallery.compactMap { k, t -> (subject: Int, score: Double)? in
                    t.compactMap { e.cosine($0) }.max().map { (k, $0) }
                }.max { $0.score < $1.score }
                out.append(Probe(subject: subject, enrolled: enrolled, best: best))
            }
        }
        return out
    }

    /// Volunteers needed in *each* of the two disjoint halves (calibration, report).
    static let minSubjectsPerHalf = 10

    /// Disjoint, deterministic volunteer split: even positions calibrate the threshold, odd positions report on it.
    static func split<T>(_ xs: [T]) -> (calibration: [T], report: [T]) {
        (xs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element), xs.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
    }

    /// 95 % Wilson score bounds for k of n. Pairs/probes within a volunteer are correlated, so these are optimistic;
    /// a subject-level bootstrap is the stricter follow-up.
    static func wilsonUpper(successes k: Int, n: Int, z: Double = 1.96) -> Double {
        guard n > 0 else { return 1 }
        let p = Double(k) / Double(n), nn = Double(n), z2 = z * z
        return min(1, (p + z2 / (2 * nn) + z * (p * (1 - p) / nn + z2 / (4 * nn * nn)).squareRoot()) / (1 + z2 / nn))
    }

    static func wilsonLower(successes k: Int, n: Int, z: Double = 1.96) -> Double {
        guard n > 0 else { return 0 }
        let p = Double(k) / Double(n), nn = Double(n), z2 = z * z
        return max(0, (p + z2 / (2 * nn) - z * (p * (1 - p) / nn + z2 / (4 * nn * nn)).squareRoot()) / (1 + z2 / nn))
    }

    static func pairs(_ sets: [[Embedding]]) -> (genuine: [Double], impostor: [Double]) {
        var genuine: [Double] = [], impostor: [Double] = []
        for (i, s) in sets.enumerated() {
            for a in s.indices { for b in s.indices where b > a { if let c = s[a].cosine(s[b]) { genuine.append(c) } } }
            for t in sets[(i + 1)...] { for x in s { for y in t { if let c = x.cosine(y) { impostor.append(c) } } } }
        }
        return (genuine, impostor)
    }

    /// Per-volunteer embedding sets (same model) → verdict.
    /// 1. Calibration half: impostor-side limit = the stricter of FAR 1e-3 on verification pairs and open-set
    ///    FPIR ≤ `maxFPIR` on held-out volunteers' top-1 matches; the threshold sits halfway to the genuine-side limit.
    /// 2. Report half (volunteers never seen in step 1): TAR, FPIR, misidentifications and coverage at that threshold,
    ///    with 95 % Wilson bounds. Pass: TAR ≥ `requiredTAR`, FPIR ≤ `maxFPIR`, zero misidentifications (D28).
    static func evaluate(subjects: [[Embedding]], modelID: String, now: Date = .now) -> Verdict {
        let sets = subjects.map { $0.filter { $0.modelID == modelID } }.filter { $0.count >= 4 }
        let (cal, rep) = split(sets)
        guard cal.count >= minSubjectsPerHalf, rep.count >= minSubjectsPerHalf else { return .insufficientData }

        let c = pairs(cal)
        guard c.impostor.count >= minImpostorPairs, let op = tarAtFAR(genuine: c.genuine, impostor: c.impostor, far: far)
        else { return .insufficientData }
        let calUnknown = openSetProbes(cal).filter { !$0.enrolled }.map { $0.best?.score ?? -1 }.sorted(by: >)
        guard !calUnknown.isEmpty else { return .insufficientData }
        let k = Int((maxFPIR * Double(calUnknown.count)).rounded(.down))
        // Impostor-side limit: the stricter of FAR 1e-3 and open-set FPIR. Genuine-side limit: the score at which
        // calibration TAR would just reach `requiredTAR`. Operate halfway between them, so the unseen report half has
        // margin on both sides (with ~100 report probes, one stray impostor already breaks FPIR 0.5 %).
        let low = max(op.threshold, calUnknown[min(k, calUnknown.count - 1)])
        let gen = c.genuine.sorted()
        let high = gen.isEmpty ? low : gen[min(gen.count - 1, Int((1 - requiredTAR) * Double(gen.count)))]
        let threshold = high > low ? (low + high) / 2 : low

        let r = pairs(rep)
        let tarHits = r.genuine.filter { $0 > threshold }.count
        let tar = r.genuine.isEmpty ? 0 : Double(tarHits) / Double(r.genuine.count)
        let probes = openSetProbes(rep)
        let unknown = probes.filter { !$0.enrolled }.map { $0.best?.score ?? -1 }
        let fp = unknown.filter { $0 > threshold }.count
        let fpir = unknown.isEmpty ? 1 : Double(fp) / Double(unknown.count)
        let enrolled = probes.filter(\.enrolled)
        let misID = enrolled.filter { p in p.best.map { $0.score > threshold && $0.subject != p.subject } ?? false }.count
        let decided = enrolled.filter { p in p.best.map { $0.score > threshold && $0.subject == p.subject } ?? false }.count
        let coverage = enrolled.isEmpty ? 0 : Double(decided) / Double(enrolled.count)
        guard tar >= requiredTAR, fpir <= maxFPIR, misID == 0 else {
            return .fail(tar: tar, fpir: fpir, misidentifications: misID)
        }
        return .pass(FaceShipGateRecord(
            modelID: modelID, threshold: threshold, tar: tar, tarLower95: wilsonLower(successes: tarHits, n: r.genuine.count),
            far: far, fpir: fpir, fpirUpper95: wilsonUpper(successes: fp, n: unknown.count),
            misidentifications: misID, misidentificationUpper95: wilsonUpper(successes: misID, n: enrolled.count),
            coverage: coverage, folds: folds, calibrationSubjects: cal.count, reportSubjects: rep.count,
            subjectCount: sets.count, passedAt: now))
    }
}

/// What a passed benchmark leaves behind: aggregates only (no vectors, no per-volunteer rows).
struct FaceShipGateRecord: Codable, Hashable, Sendable {
    var modelID: String
    var threshold: Double
    var tar: Double
    var tarLower95: Double
    var far: Double
    var fpir: Double
    var fpirUpper95: Double
    var misidentifications: Int
    var misidentificationUpper95: Double
    /// Enrolled report probes decided correctly (not left unknown) at the threshold.
    var coverage: Double
    var folds: Int
    var calibrationSubjects: Int
    var reportSubjects: Int
    var subjectCount: Int
    var passedAt: Date

    /// Calibration earned by the benchmark: decision point at the threshold; lookalike rate = the FPIR upper bound.
    var cueModel: CueModel {
        CueModel(calibration: .init(threshold: threshold, slope: 25), lookalikeRate: max(far, fpirUpper95), lrRange: 0.01...100)
    }
}

/// The separate "Help test face recognition" consent (face-embedding.md §6.2), distinct from product consent.
struct FaceBenchConsent: Hashable, Sendable {
    static let currentVersion = 1
    var agreedAt: Date
    var version = FaceBenchConsent.currentVersion
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

/// The benchmark run: consented volunteers' face embeddings in RAM, keyed by an anonymous code. Everything is
/// deleted when the run finishes, on withdrawal, or after `maxAge` (7 days) at the latest.
@MainActor
final class FaceBenchmarkSession {
    static let maxAge: TimeInterval = 7 * 86_400
    let modelID: String
    let startedAt: Date
    private var subjects: [UUID: [Embedding]] = [:]

    init(modelID: String, startedAt: Date = .now) { self.modelID = modelID; self.startedAt = startedAt }

    /// Adds one volunteer's embeddings (from N aligned crops at registration). nil without the bench consent.
    @discardableResult
    func addSubject(_ embeddings: [Embedding], consent: FaceBenchConsent?, now: Date = .now) -> UUID? {
        expireIfNeeded(now: now)
        guard let consent, consent.version == FaceBenchConsent.currentVersion,
              now.timeIntervalSince(startedAt) <= Self.maxAge else { return nil }
        let code = UUID()
        subjects[code] = embeddings.filter { $0.modelID == modelID }.compactMap(\.normalised)
        return code
    }

    /// Withdrawal: that volunteer's embeddings are gone now (results are only computed on demand).
    func withdraw(_ code: UUID) { subjects[code] = nil }
    func deleteAll() { subjects = [:] }
    func expireIfNeeded(now: Date = .now) { if now.timeIntervalSince(startedAt) > Self.maxAge { deleteAll() } }

    /// Reads expire first, so an idle run can't hold embeddings past `maxAge`.
    func subjectCount(now: Date = .now) -> Int { expireIfNeeded(now: now); return subjects.count }
    func embeddingCount(now: Date = .now) -> Int { expireIfNeeded(now: now); return subjects.values.reduce(0) { $0 + $1.count } }
    var subjectCount: Int { subjectCount() }
    var embeddingCount: Int { embeddingCount() }

    /// Evaluates, stores the aggregate record on a pass, and deletes every embedding either way (run over).
    func finish(store: FaceShipGateStore = FaceShipGateStore(), now: Date = .now) -> FaceBenchmark.Verdict {
        expireIfNeeded(now: now)
        let v = FaceBenchmark.evaluate(subjects: Array(subjects.values), modelID: modelID)
        if case .pass(let r) = v { try? store.save(r) }
        deleteAll()
        return v
    }
}
