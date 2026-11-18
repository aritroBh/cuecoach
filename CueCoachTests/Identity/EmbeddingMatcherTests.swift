import Foundation
import Testing
@testable import CueCoach

/// Synthetic embeddings: unit vectors along an axis, optionally rotated toward another axis.
enum Synth {
    static let dim = 16
    static func axis(_ i: Int, model: String = "test.v1") -> Embedding {
        var v = [Float](repeating: 0, count: dim); v[i] = 1
        return Embedding(modelID: model, vector: v)
    }
    /// Unit vector with cosine `cos` to axis i, rest of the mass on axis j.
    static func near(_ i: Int, cos: Float, other j: Int, model: String = "test.v1") -> Embedding {
        var v = [Float](repeating: 0, count: dim)
        v[i] = cos; v[j] = (1 - cos * cos).squareRoot()
        return Embedding(modelID: model, vector: v)
    }
    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
}

@Suite struct EmbeddingTests {
    @Test func cosineOfIdenticalIsOneAndOrthogonalIsZero() {
        #expect(abs(Synth.axis(0).cosine(Synth.axis(0))! - 1) < 1e-6)
        #expect(abs(Synth.axis(0).cosine(Synth.axis(1))!) < 1e-6)
    }

    @Test func cosineIsScaleInvariant() {
        let big = Embedding(modelID: "test.v1", vector: [3, 4])
        let small = Embedding(modelID: "test.v1", vector: [0.3, 0.4])
        #expect(abs(big.cosine(small)! - 1) < 1e-6)
    }

    @Test func cosineAcrossModelsOrDimensionsIsNil() {
        #expect(Synth.axis(0).cosine(Synth.axis(0, model: "other.v2")) == nil)
        #expect(Embedding(modelID: "m", vector: [1, 0]).cosine(Embedding(modelID: "m", vector: [1, 0, 0])) == nil)
    }

    @Test func zeroOrNonFiniteVectorsNeverMatch() {
        let zero = Embedding(modelID: "test.v1", vector: [Float](repeating: 0, count: Synth.dim))
        #expect(zero.cosine(Synth.axis(0)) == nil)
        var bad = Synth.axis(0).vector; bad[1] = .nan
        #expect(Embedding(modelID: "test.v1", vector: bad).cosine(Synth.axis(0)) == nil)
    }

    @Test func meanOfTemplatesIsNormalisedAndSameModelOnly() throws {
        let m = try #require(Embedding.mean([Synth.axis(0), Synth.axis(1)]))
        #expect(abs(m.cosine(Synth.near(0, cos: 0.7071, other: 1))! - 1) < 1e-3)
        #expect(Embedding.mean([Synth.axis(0), Synth.axis(1, model: "x")]) == nil)
        #expect(Embedding.mean([]) == nil)
    }

    @Test func codecRoundTripsAndRejectsGarbage() throws {
        let set = [Synth.axis(0), Synth.near(2, cos: 0.5, other: 3)]
        let data = try EmbeddingCodec.encode(set)
        #expect(try EmbeddingCodec.decode(data) == set)
        #expect(EmbeddingCodec.decodeOrNil(Data([1, 2, 3])) == nil)
        #expect(EmbeddingCodec.decodeOrNil(nil) == nil)
    }
}

@Suite struct IdentityMatcherTests {
    let gallery: [UUID: [Embedding]] = [Synth.a: [Synth.axis(0)], Synth.b: [Synth.axis(1)], Synth.c: [Synth.axis(2)]]
    let matcher = IdentityMatcher(threshold: 0.8, margin: 0.1)

    @Test func strongProbeMatchesItsOwner() {
        let r = matcher.match(Synth.near(0, cos: 0.95, other: 5), against: gallery)
        #expect(r.decision == .match(Synth.a))
        #expect(abs((r.similarities[Synth.a] ?? 0) - 0.95) < 1e-3)
    }

    @Test func openSetRejectsStranger() {
        // A bystander: far from every enrolled player.
        let r = matcher.match(Synth.axis(9), against: gallery)
        #expect(r.decision == .unknown)
    }

    @Test func ambiguousWhenTwoPlayersAreClose() {
        // Equal cosine (~0.7 + rest) to a and b → below margin.
        var v = [Float](repeating: 0, count: Synth.dim); v[0] = 0.69; v[1] = 0.69; v[5] = 0.2
        let r = IdentityMatcher(threshold: 0.6, margin: 0.1).match(Embedding(modelID: "test.v1", vector: v), against: gallery)
        #expect(r.decision == .ambiguous)
    }

    @Test func bestExemplarPerPlayerWins() {
        let g: [UUID: [Embedding]] = [Synth.a: [Synth.axis(3), Synth.axis(0)], Synth.b: [Synth.axis(1)]]
        #expect(matcher.match(Synth.near(0, cos: 0.9, other: 7), against: g).decision == .match(Synth.a))
    }

    @Test func modelMismatchIsIgnored() {
        let r = matcher.match(Synth.axis(0, model: "old.v0"), against: gallery)
        #expect(r.decision == .unknown)
        #expect(r.similarities.isEmpty)
    }

    @Test func emptyGalleryIsUnknown() {
        #expect(matcher.match(Synth.axis(0), against: [:]).decision == .unknown)
    }

    @Test func resultHoldsNoCopyOfTheProbe() {
        // Privacy: non-matching embeddings are dropped in the same call; the result type only carries scores.
        let r = matcher.match(Synth.axis(9), against: gallery)
        let labels = Mirror(reflecting: r).children.compactMap(\.label)
        #expect(Set(labels) == ["decision", "similarities"])
    }

    @Test func plattCalibrationIsMonotonicAndCentredOnThreshold() {
        let cal = SimilarityCalibration(threshold: 0.8, slope: 20)
        #expect(abs(cal.probability(0.8) - 0.5) < 1e-9)
        #expect(cal.probability(0.95) > cal.probability(0.85))
        #expect(cal.probability(0.2) < 0.01)
        #expect(cal.probability(1.0) > 0.95)
    }
}
