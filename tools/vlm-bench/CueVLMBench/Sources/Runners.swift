import BenchCore
import CoreImage
import Foundation
import FoundationModels
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Result of a single question for any model.
struct Reply: Sendable {
    var raw: String
    var answer: Answer?
    var parseError: String?
    var firstTokenSeconds: Double?
    var promptTokens: Int?
    var outputTokens: Int?
}

@MainActor protocol VLMRunner: AnyObject {
    var id: String { get }
    var info: [String: String] { get }
    /// Loads weights / warms the model. Returns nothing; caller times it.
    func load() async throws
    func ask(_ q: Question, images: [URL]) async throws -> Reply
}

// MARK: - Apple Foundation Models (on-device system model, guided generation)

@Generable struct BallsG {
    @Guide(description: "Numbers (1-15) of every object ball visible on the table")
    var balls: [Int]
    @Guide(description: "Whether the plain white cue ball is on the table")
    var cueBallPresent: Bool
}

@Generable struct KitchenG {
    @Guide(description: "True if the cue ball is between the head rail (bottom) and the head string line")
    var inKitchen: Bool
}

@Generable enum PocketG: String {
    case headLeft, headRight, sideLeft, sideRight, footLeft, footRight
}

@Generable struct PocketDropG {
    var pocket: PocketG
}

@Generable struct LabelG {
    @Guide(description: "A punchy highlight label of one or two words, no numbers")
    var label: String
}

final class FoundationModelRunner: VLMRunner {
    let id = "apple-fm"
    var info: [String: String] = [:]

    func load() async throws {
        let model = SystemLanguageModel.default
        info["availability"] = "\(model.availability)"
        info["vision"] = "\(model.capabilities.contains(.vision))"
        info["guidedGeneration"] = "\(model.capabilities.contains(.guidedGeneration))"
        guard model.isAvailable else { throw BenchError.unavailable("SystemLanguageModel: \(model.availability)") }
        // Cold start: first tiny request forces the model resident.
        let s = LanguageModelSession(instructions: Prompts.system)
        info["contextSize"] = "\(await model.contextSize)"
        _ = try await s.respond(to: "Reply with the single word OK.")
    }

    func ask(_ q: Question, images: [URL]) async throws -> Reply {
        switch q.kind {
        case .ballsOnTable:
            return try await run(q, images, BallsG.self) { g in
                Answer(balls: g.balls, cueBallPresent: g.cueBallPresent)
            }
        case .cueInKitchen:
            return try await run(q, images, KitchenG.self) { Answer(inKitchen: $0.inKitchen) }
        case .pocketDrop:
            return try await run(q, images, PocketDropG.self) { Answer(pocket: Pocket(rawValue: $0.pocket.rawValue)) }
        case .shotLabel:
            return try await run(q, images, LabelG.self) { Answer(label: $0.label) }
        }
    }

    private func run<T: Generable>(_ q: Question, _ images: [URL], _ type: T.Type,
                                   _ map: (T) -> Answer) async throws -> Reply {
        // Fresh session per question: no context bleed, stays well inside the 4K window.
        let session = LanguageModelSession(instructions: Prompts.system)
        let text = Prompts.question(q)
        let t0 = Metrics.now()
        var first: Double?
        var last: GeneratedContent?
        let stream = session.streamResponse(generating: T.self,
                                            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)) {
            text
            for url in images { Attachment(imageURL: url) }
        }
        for try await snap in stream {
            if first == nil { first = Metrics.now() - t0 }
            last = snap.rawContent
        }
        guard let last else { return Reply(raw: "", answer: nil, parseError: "empty stream", firstTokenSeconds: first) }
        var reply = Reply(raw: last.jsonString, answer: nil, parseError: nil, firstTokenSeconds: first)
        do {
            let value = try T(last)
            var a = map(value)
            // Same validation as the JSON path: out-of-range ball numbers are a schema failure.
            if let b = a.balls, b.contains(where: { !(1...15).contains($0) }) {
                reply.parseError = "ball out of range"; a = Answer()
                reply.answer = nil
            } else {
                reply.answer = a
            }
        } catch {
            reply.parseError = "\(error)"
        }
        return reply
    }
}

// MARK: - MLX VLMs (Qwen3.5, Gemma 4, ...) from local weights, JSON prompted

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Never used: weights are local. Exists only to satisfy the loader API and to prove no network path.
struct NoNetworkDownloader: Downloader {
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        throw BenchError.unavailable("network download attempted for \(id) — weights must be local")
    }
}

final class MLXRunner: VLMRunner {
    let id: String
    let directory: URL
    let eos: Set<String>
    var info: [String: String] = [:]
    private var container: ModelContainer?

    init(id: String, directory: URL, eos: Set<String>) {
        self.id = id; self.directory = directory; self.eos = eos
    }

    func load() async throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw BenchError.unavailable("weights missing at \(directory.path)")
        }
        info["weightsMB"] = String(format: "%.0f", Metrics.directorySizeMB(directory))
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        // First GPU op builds the Metal device + runtime-compiles the 9 non-JIT kernel files (bench-only
        // cost: a shipping build uses a precompiled metallib). Timed separately so load time stays honest.
        let k0 = Metrics.now()
        let probe = MLXArray([1, 2, 3] as [Float]).sum()
        eval(probe)
        info["mlxKernelCompileSeconds"] = String(format: "%.2f", Metrics.now() - k0)
        let config = ModelConfiguration(directory: directory, extraEOSTokens: eos)
        container = try await VLMModelFactory.shared.loadContainer(
            from: NoNetworkDownloader(), using: LocalTokenizerLoader(), configuration: config)
    }

    func ask(_ q: Question, images: [URL]) async throws -> Reply {
        guard let container else { throw BenchError.unavailable("not loaded") }
        let session = ChatSession(
            container,
            instructions: Prompts.system,
            generateParameters: GenerateParameters(maxTokens: 200, temperature: 0),
            processing: .init(resize: CGSize(width: 1024, height: 1024)),
            additionalContext: ["enable_thinking": false])
        let prompt = Prompts.question(q) + "\n" + Prompts.jsonSchemaHint(q.kind)
        let t0 = Metrics.now()
        var first: Double?
        var raw = ""
        var reply = Reply(raw: "")
        for try await g in session.streamDetails(to: prompt, images: images.map { .url($0) }) {
            switch g {
            case .chunk(let s):
                if first == nil { first = Metrics.now() - t0 }
                raw += s
            case .info(let i):
                reply.promptTokens = i.promptTokenCount
                reply.outputTokens = i.generationTokenCount
            default: break
            }
        }
        reply.raw = raw
        reply.firstTokenSeconds = first
        do { reply.answer = try AnswerParser.parse(q.kind, text: raw) } catch { reply.parseError = "\(error)" }
        MLX.GPU.clearCache()
        return reply
    }
}

enum BenchError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String {
        switch self { case .unavailable(let s): s }
    }
}
