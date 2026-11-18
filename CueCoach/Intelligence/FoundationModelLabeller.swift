import Foundation
import Rules
import Engine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Engine-derived context for Shot of the Game labelling (SPEC §5.9, §9, D23: text-only from engine numbers, never pixels).
struct HighlightLabelContext: Hashable, Sendable {
    var ruleSet: RuleSetID
    var rating: DecisionRating
    var wonRack: Bool
    var isSafety: Bool
    var isClutch: Bool
    var wpaDelta: Double
    var baselineMakeProbability: Double
}

/// Validated highlight label guaranteed to satisfy SPEC §2, §5.9, §9 & D23 (1–2 letter-only words, zero digits).
struct HighlightLabel: Hashable, Sendable {
    let value: String
    fileprivate init(validated value: String) {
        self.value = value
    }
}

/// Non-real-time post-rack highlight labeller (never invoked while aiming).
/// Raw candidates are always passed through `FoundationModelLabeller.resolve` before leaving the boundary.
protocol HighlightLabelling: Sendable {
    func rawCandidate(for context: HighlightLabelContext) async -> String?
}

#if canImport(FoundationModels)
@Generable
private struct GeneratedHighlightLabel {
    @Guide(description: "Punchy pool highlight title of one or two words, letters and spaces only, never numbers")
    var label: String
}
#endif

/// On-device `SystemLanguageModel.default` prompt + `@Generable` schema, paired with post-hoc validation and
/// deterministic rule fallback on simulator, unavailability, refusal, or cooperative 2.2 s timeout (D23).
struct SystemFoundationModelLabeller: HighlightLabelling {
    static let timeoutMilliseconds = 2200
    static let maxResponseTokens = 64

    func rawCandidate(for context: HighlightLabelContext) async -> String? {
        #if targetEnvironment(simulator)
        return nil
        #elseif canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.capabilities.contains(.guidedGeneration) else { return nil }
        let prompt = FoundationModelLabeller.prompt(for: context)
        // Cooperative deadline: `cancelAll()` cancels the losing child and awaits structured teardown.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    if Task.isCancelled { return nil }
                    let session = LanguageModelSession(instructions: FoundationModelLabeller.systemInstructions)
                    let response = try await session.respond(
                        to: prompt,
                        schema: GeneratedHighlightLabel.generationSchema,
                        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.maxResponseTokens)
                    )
                    if Task.isCancelled { return nil }
                    return try GeneratedHighlightLabel(response.content).label
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Self.timeoutMilliseconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }
}

enum FoundationModelLabeller {
    static let ultimateFallback = "Key Shot"
    static let maxCharacterLength = 22

    static let systemInstructions = """
        You title memorable pool shots in one or two short words. \
        Use letters and spaces only. Never output digits, punctuation, or sentences.
        """

    private static let blockedTokens: Set<String> = [
        "sorry", "cannot", "cant", "unable", "assist", "apologize", "unclear", "unsure",
        "none", "null", "unknown", "label", "title", "ok", "okay",
        "eight", "nine", "ball", "bar", "tournament"
    ]

    /// Qualitative description derived from engine numbers with zero digits in the prompt so the model isn't primed to echo numbers.
    static func prompt(for c: HighlightLabelContext) -> String {
        let gameWords: String = switch c.ruleSet {
        case .barEight: "casual rack"
        case .wpaEight: "call-shot rack"
        case .wpaNine: "rotation rack"
        }
        let swingWords = abs(c.wpaDelta) >= 0.30 ? "massive momentum swing" : (abs(c.wpaDelta) >= 0.15 ? "strong swing" : "steady edge")
        let oddsWords = c.baselineMakeProbability <= 0.30 ? "very low make odds" : (c.baselineMakeProbability <= 0.55 ? "tough shot" : "clean make")
        let kindWords = c.isSafety ? "defensive safety" : (c.wonRack ? "rack-winning pot" : "offensive pot")
        let clutchWords = c.isClutch ? ", high-pressure clutch moment" : ""
        let ratingWords = c.rating == .brilliant ? ", brilliant impact" : ""
        return "Label this \(gameWords) \(kindWords) (\(oddsWords), \(swingWords)\(clutchWords)\(ratingWords)) in one or two words."
    }

    /// Resolves and validates both the model candidate and the fallback at a single typed boundary.
    static func resolve(using labeller: any HighlightLabelling,
                        for context: HighlightLabelContext,
                        fallback: String) async -> HighlightLabel {
        let raw = await labeller.rawCandidate(for: context)
        return HighlightLabel(validated: validated(raw, fallback: fallback))
    }

    /// Enforces SPEC §2, §5.9, §9 & D23 on both `candidate` and `fallback`: 1–2 words, letters only, zero digits, non-refusal.
    static func validated(_ candidate: String?, fallback: String) -> String {
        if let clean = sanitize(candidate) {
            return clean
        }
        if let cleanFallback = sanitize(fallback) {
            return cleanFallback
        }
        return ultimateFallback
    }

    private static func sanitize(_ input: String?) -> String? {
        guard let input else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty, trimmed.allSatisfy({ !$0.isNumber }) else { return nil }
        let rawWords = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard (1...2).contains(rawWords.count) else { return nil }
        var normalized: [String] = []
        for word in rawWords {
            guard word.count >= 2, word.allSatisfy({ $0.isLetter }) else { return nil }
            let lower = word.lowercased()
            guard !blockedTokens.contains(lower) else { return nil }
            normalized.append(lower.prefix(1).uppercased() + lower.dropFirst())
        }
        let joined = normalized.joined(separator: " ")
        return joined.count <= maxCharacterLength ? joined : nil
    }
}
