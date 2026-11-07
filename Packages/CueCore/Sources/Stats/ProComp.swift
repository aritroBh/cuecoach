import Foundation

// Pro comparisons (SPEC §8). Every trait is sourced or flagged `estimated` (Phase 6 acceptance).

public enum TraitConfidence: String, Codable, Sendable, CaseIterable { case low, medium, high }

public struct ProTrait: Hashable, Codable, Sendable {
    /// Same scale as `ArchetypeVector`: [0, 1].
    public var value: Double
    /// `true` = qualitative judgement, not measured from match data.
    public var estimated: Bool
    /// Where the value (or the reputation behind an estimate) comes from. Required when `estimated == false`.
    public var source: String?
    public var confidence: TraitConfidence
    /// What the source actually supports.
    public var note: String?

    public init(value: Double, estimated: Bool, source: String? = nil, confidence: TraitConfidence, note: String? = nil) {
        self.value = value
        self.estimated = estimated
        self.source = source
        self.confidence = confidence
        self.note = note
    }
}

public struct ProProfile: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var nickname: String?
    /// Identity / biography source.
    public var profileSource: String?
    public var traits: [ArchetypeDimension: ProTrait]

    public init(id: String, name: String, nickname: String?, profileSource: String?, traits: [ArchetypeDimension: ProTrait]) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.profileSource = profileSource
        self.traits = traits
    }

    public var vector: ArchetypeVector { ArchetypeVector(values: traits.mapValues(\.value)) }
}

public enum ProProfiles {
    public enum ValidationError: Error, Equatable {
        case unsourcedMeasuredTrait(pro: String, trait: String)
        case valueOutOfRange(pro: String, trait: String)
        case nonHTTPSSource(pro: String, trait: String)
        case duplicateID(String)
    }

    struct Bundle: Codable { var version: Int; var profiles: [ProProfile] }

    /// Decodes and validates a `ProProfiles.json` document.
    public static func decode(_ data: Data) throws -> [ProProfile] {
        let profiles = try JSONDecoder().decode(Bundle.self, from: data).profiles
        var ids = Set<String>()
        for p in profiles {
            guard ids.insert(p.id).inserted else { throw ValidationError.duplicateID(p.id) }
            for (d, t) in p.traits {
                guard t.value.isFinite, (0...1).contains(t.value) else {
                    throw ValidationError.valueOutOfRange(pro: p.id, trait: d.rawValue)
                }
                if let s = t.source, !s.hasPrefix("https://") {
                    throw ValidationError.nonHTTPSSource(pro: p.id, trait: d.rawValue)
                }
                if !t.estimated, t.source == nil {
                    throw ValidationError.unsourcedMeasuredTrait(pro: p.id, trait: d.rawValue)
                }
            }
        }
        return profiles
    }

    /// The bundled seed profiles (`ProProfilesData.swift`).
    public static func bundled() throws -> [ProProfile] {
        try decode(Data(proProfilesJSON.utf8))
    }
}

/// Closest pro for a player. Field names match the app's persisted `StoredProComp`.
public struct ProComp: Hashable, Codable, Sendable {
    public var proID: String
    /// (1 + r) / 2 where r is the cosine similarity of the mean-centred vectors over shared dimensions
    /// (Pearson r): 1 = same style shape, 0.5 = unrelated, 0 = opposite.
    public var similarity: Double
    /// Up to two dimensions (raw values) where both the player and the pro are above their own average.
    public var sharedTraits: [String]

    public init(proID: String, similarity: Double, sharedTraits: [String]) {
        self.proID = proID
        self.similarity = similarity
        self.sharedTraits = sharedTraits
    }

    /// Minimum shared dimensions for a meaningful comparison.
    public static let minSharedDimensions = 3

    /// Cosine similarity of mean-centred vectors (style shape, independent of overall skill level), mapped to [0, 1].
    /// `nil` with fewer than `minSharedDimensions` shared dimensions or a flat vector.
    public static func similarity(_ v: ArchetypeVector, _ pro: ProProfile) -> Double? {
        guard let (a, b, _) = centred(v, pro) else { return nil }
        let dot = zip(a, b).map(*).reduce(0, +)
        let na = a.map { $0 * $0 }.reduce(0, +).squareRoot()
        let nb = b.map { $0 * $0 }.reduce(0, +).squareRoot()
        guard na > 1e-12, nb > 1e-12 else { return nil }
        let r = max(-1, min(1, dot / (na * nb)))
        return (1 + r) / 2
    }

    /// Most similar pro (ties → lowest id), or `nil` when no pro can be compared.
    /// Callers gate on `Archetypes.isUnlocked` (done by `Archetypes.snapshot`).
    public static func nearest(to v: ArchetypeVector, among pros: [ProProfile]) -> ProComp? {
        let scored = pros.compactMap { p in similarity(v, p).map { (p, $0) } }
        guard let best = scored.min(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }) else { return nil }
        guard let (a, b, dims) = centred(v, best.0) else { return nil }
        let shared = zip(dims, zip(a, b)).filter { $0.1.0 > 1e-12 && $0.1.1 > 1e-12 }
            .sorted { l, r in
                let pl = l.1.0 * l.1.1, pr = r.1.0 * r.1.1
                return pl != pr ? pl > pr : l.0.rawValue < r.0.rawValue
            }
            .prefix(2).map(\.0.rawValue)
        return ProComp(proID: best.0.id, similarity: best.1, sharedTraits: Array(shared))
    }

    private static func centred(_ v: ArchetypeVector, _ pro: ProProfile)
        -> ([Double], [Double], [ArchetypeDimension])? {
        let dims = ArchetypeDimension.allCases.filter { v[$0] != nil && pro.traits[$0] != nil }
        guard dims.count >= minSharedDimensions else { return nil }
        let a = dims.map { v[$0]! }, b = dims.map { pro.traits[$0]!.value }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        return (a.map { $0 - ma }, b.map { $0 - mb }, dims)
    }
}
