import BenchCore
import Foundation
import SwiftUI
import UIKit

@main
struct BenchApp: App {
    @State private var bench = Bench()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("VLM Bench").font(.largeTitle.bold())
                Text(bench.status).font(.title3).monospaced()
                ProgressView(value: bench.progress)
                Text(bench.log).font(.footnote).monospaced().frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding()
            .task { await bench.runFromLaunchArguments() }
        }
    }
}

struct QuestionResult: Codable {
    var id: String
    var kind: QuestionKind
    var latencySeconds: Double
    var firstTokenSeconds: Double?
    var promptTokens: Int?
    var outputTokens: Int?
    var raw: String
    var answer: Answer?
    var parseError: String?
    var error: String?
    var score: Score
    var thermal: String
}

struct RunResult: Codable {
    var model: String
    var device: String
    var os: String
    var startedAt: Date
    var loadSeconds: Double?
    var loadError: String?
    var info: [String: String]
    var appBundleMB: Double
    var memoryBeforeLoad: Metrics.Memory
    var memoryAfterLoad: Metrics.Memory?
    var memoryEnd: Metrics.Memory?
    var thermalStart: String
    var thermalEnd: String?
    var wallSeconds: Double?
    var questions: [QuestionResult] = []
    var summary: [String: Double] = [:]
}

@MainActor @Observable final class Bench {
    var status = "idle"
    var progress = 0.0
    var log = ""

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func runner(for model: String) -> VLMRunner? {
        let models = documents.appendingPathComponent("Models")
        switch model {
        case "apple-fm": return FoundationModelRunner()
        case "qwen3.5-2b":
            return MLXRunner(id: model, directory: models.appendingPathComponent("Qwen3.5-2B-MLX-4bit"), eos: ["<|im_end|>"])
        case "gemma4-e2b":
            return MLXRunner(id: model, directory: models.appendingPathComponent("gemma-4-e2b-it-4bit"), eos: ["<turn|>"])
        default: return nil
        }
    }

    func runFromLaunchArguments() async {
        let args = ProcessInfo.processInfo.arguments
        var model = "apple-fm"
        var limit = Int.max
        if let i = args.firstIndex(of: "-model"), i + 1 < args.count { model = args[i + 1] }
        if let i = args.firstIndex(of: "-limit"), i + 1 < args.count { limit = Int(args[i + 1]) ?? .max }
        guard let r = runner(for: model) else { status = "unknown model \(model)"; return }
        UIApplication.shared.isIdleTimerDisabled = true
        await run(r, limit: limit)
    }

    func run(_ runner: VLMRunner, limit: Int) async {
        let testDir = Bundle.main.bundleURL.appendingPathComponent("TestSet")
        let set: TestSet
        do { set = try TestSet.decode(Data(contentsOf: testDir.appendingPathComponent("testset.json"))) } catch {
            status = "testset: \(error)"; return
        }
        var result = RunResult(model: runner.id, device: Metrics.deviceModel(),
                               os: ProcessInfo.processInfo.operatingSystemVersionString, startedAt: Date(),
                               info: [:], appBundleMB: Metrics.directorySizeMB(Bundle.main.bundleURL),
                               memoryBeforeLoad: Metrics.memory(), thermalStart: Metrics.thermal())
        let wall0 = Metrics.now()
        status = "\(runner.id): loading"
        write(result)
        let t0 = Metrics.now()
        do {
            try await runner.load()
            result.loadSeconds = Metrics.now() - t0
        } catch {
            result.loadError = "\(error)"
        }
        result.info = runner.info
        result.memoryAfterLoad = Metrics.memory()
        write(result)
        if result.loadError == nil {
            let qs = Array(set.questions.prefix(limit))
            for (n, q) in qs.enumerated() {
                status = "\(runner.id): \(n + 1)/\(qs.count) \(q.id)"
                progress = Double(n) / Double(qs.count)
                let urls = q.images.map { testDir.appendingPathComponent($0) }
                let s = Metrics.now()
                var qr: QuestionResult
                do {
                    let reply = try await runner.ask(q, images: urls)
                    qr = QuestionResult(id: q.id, kind: q.kind, latencySeconds: Metrics.now() - s,
                                        firstTokenSeconds: reply.firstTokenSeconds, promptTokens: reply.promptTokens,
                                        outputTokens: reply.outputTokens, raw: reply.raw, answer: reply.answer,
                                        parseError: reply.parseError, error: nil,
                                        score: Scorer.score(q, reply.answer), thermal: Metrics.thermal())
                } catch {
                    qr = QuestionResult(id: q.id, kind: q.kind, latencySeconds: Metrics.now() - s, raw: "",
                                        error: "\(error)", score: Scorer.score(q, nil), thermal: Metrics.thermal())
                }
                log = "\(q.id): \(qr.score.correct ? "OK" : "x") \(String(format: "%.2fs", qr.latencySeconds)) \(qr.raw.prefix(80))"
                result.questions.append(qr)
                if n % 5 == 4 { write(result) }
            }
        }
        result.memoryEnd = Metrics.memory()
        result.thermalEnd = Metrics.thermal()
        result.wallSeconds = Metrics.now() - wall0
        result.summary = summarize(result.questions)
        write(result, done: true)
        progress = 1
        status = "\(runner.id): done \(String(format: "%.0f%%", (result.summary["accuracy"] ?? 0) * 100))"
    }

    func summarize(_ qs: [QuestionResult]) -> [String: Double] {
        guard !qs.isEmpty else { return [:] }
        var s: [String: Double] = [:]
        s["n"] = Double(qs.count)
        s["accuracy"] = Double(qs.filter(\.score.correct).count) / Double(qs.count)
        s["schemaValidRate"] = Double(qs.filter { $0.answer != nil }.count) / Double(qs.count)
        for kind in QuestionKind.allCases {
            let k = qs.filter { $0.kind == kind }
            guard !k.isEmpty else { continue }
            s["acc.\(kind.rawValue)"] = Double(k.filter(\.score.correct).count) / Double(k.count)
            s["partial.\(kind.rawValue)"] = k.map(\.score.partial).reduce(0, +) / Double(k.count)
            s["latencyMedian.\(kind.rawValue)"] = Stats.median(k.map(\.latencySeconds))
        }
        let lat = qs.filter { $0.error == nil }.map(\.latencySeconds)
        s["latencyMedian"] = Stats.median(lat)
        s["latencyP90"] = Stats.percentile(lat, 0.9)
        s["firstTokenMedian"] = Stats.median(qs.compactMap(\.firstTokenSeconds))
        s["labelFormatValidRate"] = {
            let l = qs.filter { $0.kind == .shotLabel }
            return l.isEmpty ? nil : Double(l.filter(\.score.formatValid).count) / Double(l.count)
        }()
        return s
    }

    func write(_ r: RunResult, done: Bool = false) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(r) else { return }
        try? data.write(to: documents.appendingPathComponent("results-\(r.model).json"))
        if done { try? data.write(to: documents.appendingPathComponent("results.json")) }
    }
}
