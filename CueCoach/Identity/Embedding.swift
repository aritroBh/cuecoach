import Foundation

// Player identity: pure matching math (SPEC §5.8, docs/research/mesh-identity.md §7).
// No Vision, no I/O, no network in this file.

/// One appearance or face vector tagged with the model that produced it.
/// Vectors from different models (or model versions) are never compared.
struct Embedding: Hashable, Codable, Sendable {
    var modelID: String
    var vector: [Float]

    /// Cosine similarity in [-1, 1]; nil for model/dimension mismatch, zero or non-finite vectors.
    func cosine(_ other: Embedding) -> Double? {
        guard modelID == other.modelID, vector.count == other.vector.count, !vector.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in vector.indices {
            let x = Double(vector[i]), y = Double(other.vector[i])
            dot += x * y; na += x * x; nb += y * y
        }
        guard dot.isFinite, na.isFinite, nb.isFinite, na > 0, nb > 0 else { return nil }
        return min(1, max(-1, dot / (na.squareRoot() * nb.squareRoot())))
    }

    /// L2-normalised copy; nil for zero or non-finite vectors.
    var normalised: Embedding? {
        let n = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard n.isFinite, n > 0 else { return nil }
        return Embedding(modelID: modelID, vector: vector.map { Float(Double($0) / n) })
    }

    /// Normalised mean of normalised templates (all same model + dimension); nil otherwise.
    static func mean(_ items: [Embedding]) -> Embedding? {
        guard let first = items.first,
              items.allSatisfy({ $0.modelID == first.modelID && $0.vector.count == first.vector.count }) else { return nil }
        let units = items.compactMap(\.normalised)
        guard units.count == items.count else { return nil }
        var sum = [Double](repeating: 0, count: first.vector.count)
        for u in units { for i in sum.indices { sum[i] += Double(u.vector[i]) } }
        return Embedding(modelID: first.modelID, vector: sum.map { Float($0) }).normalised
    }
}

/// On-disk form of a template set inside `RecognitionData.faceEmbedding` / `.appearanceEmbedding`.
enum EmbeddingCodec {
    static let formatVersion = 1
    private struct Envelope: Codable { var format: Int; var items: [Embedding] }

    static func encode(_ items: [Embedding]) throws -> Data {
        try JSONEncoder().encode(Envelope(format: formatVersion, items: items))
    }

    static func decode(_ data: Data) throws -> [Embedding] {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard env.format == formatVersion else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "format \(env.format)")) }
        return env.items
    }

    static func decodeOrNil(_ data: Data?) -> [Embedding]? {
        guard let data else { return nil }
        return try? decode(data)
    }
}

/// Open-set nearest-template matcher. Holds no state; the probe is never retained or returned.
struct IdentityMatcher: Sendable {
    enum Decision: Hashable, Sendable { case match(UUID), ambiguous, unknown }
    struct Result: Sendable {
        var decision: Decision
        /// Best cosine per player whose templates share the probe's model.
        var similarities: [UUID: Double]
    }

    var threshold: Double
    var margin: Double

    func match(_ probe: Embedding, against gallery: [UUID: [Embedding]]) -> Result {
        var sims: [UUID: Double] = [:]
        for (player, templates) in gallery {
            if let best = templates.compactMap({ probe.cosine($0) }).max() { sims[player] = best }
        }
        let ranked = sims.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
        guard let top = ranked.first, top.value >= threshold else { return Result(decision: .unknown, similarities: sims) }
        if ranked.count > 1, top.value - ranked[1].value < margin { return Result(decision: .ambiguous, similarities: sims) }
        return Result(decision: .match(top.key), similarities: sims)
    }
}

/// Platt-style logistic map from cosine to a match likelihood in (0, 1).
/// Defaults are assumptions until the replay study (research §9.3) fits them.
struct SimilarityCalibration: Hashable, Sendable {
    var threshold: Double
    var slope: Double
    func probability(_ cosine: Double) -> Double { 1 / (1 + exp(-slope * (cosine - threshold))) }
}
