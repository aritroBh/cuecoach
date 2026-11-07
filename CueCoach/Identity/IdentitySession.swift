import Foundation

// Session identity state (research §7.2). RAM only: nothing here is written to disk.

/// Immutable copy handed to a `ShooterIdentifier` off the main actor.
struct IdentitySnapshot: Sendable {
    var roster: IdentityRoster
    var appearanceGallery: [UUID: [Embedding]]
    var faceGallery: [UUID: [Embedding]]
}

struct ShooterIdentification: Sendable {
    var attribution: Attribution
    /// Appearance of the shooting track; present only when it could teach some clothes-consented player
    /// (it resembles their template, or seeds them on their own turn). Never a non-consented person's vector.
    var shooterAppearance: Embedding?
    var evidence: [TrackEvidence] = []
}

struct AttributionStats: Hashable, Sendable {
    var total = 0
    var auto = 0
    var turnOrder = 0
    /// Shots whose shooter was changed by a tap.
    var tapped = 0
    /// Phase 5 metric (research Q16 proposal): fraction right before any tap.
    var correctBeforeTap: Double { total == 0 ? 1 : Double(total - tapped) / Double(total) }
}

@MainActor
final class IdentitySession {
    static let maxExemplars = 8

    private struct Record {
        var original: Attribution
        var current: Attribution
        var sample: Embedding?
        var expectedShooter: UUID?
        /// Player whose template `sample` was added to (turn-order bind or tap), so a later tap can undo it.
        var boundTo: UUID?
    }

    let faceModelID: String
    let bodyModelID: String
    private(set) var roster: IdentityRoster
    private var appearance: [UUID: [Embedding]] = [:]
    private var appearanceSeedCount: [UUID: Int] = [:]
    private var face: [UUID: [Embedding]] = [:]
    private var records: [UUID: Record] = [:]
    /// Bumped by revoke/end so an in-flight identification computed from older templates is discarded.
    private var epoch = 0
    private(set) var hasEnded = false

    init(profiles: [PlayerProfile], guests: [UUID] = [], faceModelID: String, bodyModelID: String) {
        self.faceModelID = faceModelID
        self.bodyModelID = bodyModelID
        var entries: [RosterEntry] = []
        for p in profiles {
            let r = p.recognition
            let consent = RecognitionConsent(faceData: r?.faceEmbedding, appearanceData: r?.appearanceEmbedding)
            entries.append(RosterEntry(playerID: p.id, consent: consent))
            let t = IdentityTemplates(r, faceModelID: faceModelID, bodyModelID: bodyModelID)
            if consent.face, !t.face.isEmpty { face[p.id] = t.face }
            if consent.clothes, !t.body.isEmpty {
                let seeds = Array(t.body.prefix(Self.maxExemplars / 2))
                appearance[p.id] = seeds
                appearanceSeedCount[p.id] = seeds.count
            }
        }
        for g in guests where !entries.contains(where: { $0.playerID == g }) {
            entries.append(RosterEntry(playerID: g, consent: .none, isGuest: true))
        }
        roster = IdentityRoster(entries: entries)
    }

    func snapshot() -> IdentitySnapshot {
        IdentitySnapshot(roster: roster, appearanceGallery: appearance, faceGallery: face)
    }

    /// Session-only clothes consent for a guest (no profile, nothing stored). Off unless granted (research Q8).
    func grantGuestClothesConsent(_ guest: UUID) {
        guard let i = roster.entries.firstIndex(where: { $0.playerID == guest && $0.isGuest }) else { return }
        roster.entries[i].consent.clothes = true
    }

    /// Tap-to-bind / turn-order bind: seeds or extends a clothes-consented player's session template.
    @discardableResult
    func bind(_ player: UUID, appearance e: Embedding) -> Bool {
        guard roster.consent(of: player).clothes, e.modelID == bodyModelID, let n = e.normalised else { return false }
        var list = appearance[player] ?? []
        list.append(n)
        let seeds = appearanceSeedCount[player] ?? 0
        while list.count > Self.maxExemplars { list.remove(at: seeds) }   // evict oldest non-seed
        appearance[player] = list
        return true
    }

    private func mayHold(_ e: Embedding, expected: UUID?) -> Bool {
        e.modelID == bodyModelID && AppearanceLearning.mayHold(e, roster: roster, gallery: appearance, expectedShooter: expected)
    }

    private func canTeach(_ e: Embedding, _ p: UUID, expected: UUID?) -> Bool {
        AppearanceLearning.canTeach(e, p, roster: roster, gallery: appearance, expectedShooter: expected)
    }

    /// Removes one learned (non-seed) exemplar again.
    private func unbind(_ player: UUID, appearance e: Embedding) {
        guard let n = e.normalised, var list = appearance[player] else { return }
        let seeds = appearanceSeedCount[player] ?? 0
        if let i = list.indices.last(where: { $0 >= seeds && list[$0] == n }) { list.remove(at: i) }
        appearance[player] = list.isEmpty ? nil : list
    }

    func record(shot: UUID, _ id: ShooterIdentification, expectedShooter: UUID? = nil) {
        guard !hasEnded else { return }
        let keep = id.shooterAppearance.flatMap { mayHold($0, expected: expectedShooter) ? $0 : nil }
        var r = Record(original: id.attribution, current: id.attribution, sample: keep, expectedShooter: expectedShooter)
        // Turn-order bind (research §7.2): a consented player with no template is seeded on their own turn.
        let p = id.attribution.playerID
        if let s = keep, p == expectedShooter, appearance[p]?.isEmpty ?? true, canTeach(s, p, expected: expectedShooter),
           bind(p, appearance: s) {
            r.boundTo = p
        }
        records[shot] = r
    }

    func identifyShot(_ shot: UUID, window: StrokeWindow, expectedShooter: UUID, teamInTurn: Set<UUID>?,
                      using identifier: some ShooterIdentifier) async -> Attribution {
        // A revoke or end during the off-actor await invalidates the result: redo it from the current snapshot.
        for _ in 0..<3 where !hasEnded {
            let started = epoch
            let result = await identifier.identify(window, snapshot: snapshot(), expectedShooter: expectedShooter,
                                                   teamInTurn: teamInTurn)
            guard epoch == started, !hasEnded else { continue }
            record(shot: shot, result, expectedShooter: expectedShooter)
            return result.attribution
        }
        let fallback = Attribution(playerID: expectedShooter, source: .turnOrder, confidence: 0, shooterTrackID: nil)
        record(shot: shot, ShooterIdentification(attribution: fallback, shooterAppearance: nil), expectedShooter: expectedShooter)
        return fallback
    }

    func attribution(for shot: UUID) -> Attribution? { records[shot]?.current }

    /// One tap on the post-shot card (any phone). Becomes session training signal for the player tapped,
    /// only if they consented to clothes and the sample plausibly is them; a wrong earlier bind is undone.
    func correct(shot: UUID, to player: UUID) -> Attribution? {
        guard var r = records[shot], roster.contains(player) else { return nil }
        r.current = Attribution(playerID: player, source: .tap, confidence: 1, shooterTrackID: r.original.shooterTrackID)
        if let s = r.sample, let b = r.boundTo, b != player { unbind(b, appearance: s); r.boundTo = nil }
        if let s = r.sample, r.boundTo == nil, canTeach(s, player, expected: r.expectedShooter), bind(player, appearance: s) {
            r.boundTo = player
        }
        if r.boundTo == nil { r.sample = nil }
        records[shot] = r
        return r.current
    }

    /// Shooter vectors held in RAM, waiting for a tap (not yet part of any template).
    var pendingSampleCount: Int { records.values.filter { $0.sample != nil && $0.boundTo == nil }.count }

    var stats: AttributionStats {
        var s = AttributionStats()
        for r in records.values {
            s.total += 1
            if r.original.source == .auto { s.auto += 1 } else if r.original.source == .turnOrder { s.turnOrder += 1 }
            if r.current.source == .tap, r.current.playerID != r.original.playerID { s.tapped += 1 }
        }
        return s
    }

    /// `IdentityRevoke` or local delete: purge this player's identity data now.
    func revoke(_ player: UUID) {
        epoch += 1
        appearance[player] = nil
        appearanceSeedCount[player] = nil
        face[player] = nil
        if let i = roster.entries.firstIndex(where: { $0.playerID == player }) { roster.entries[i].consent = .none }
        for (k, r) in records {
            var r = r
            if r.boundTo == player { r.boundTo = nil }
            // Drop anything held for this player or no longer justified by anyone else's consent.
            if r.current.playerID == player || r.original.playerID == player { r.sample = nil }
            if let s = r.sample, r.boundTo == nil, !mayHold(s, expected: r.expectedShooter) { r.sample = nil }
            records[k] = r
        }
    }

    /// Session end: drop everything.
    func end() {
        epoch += 1
        hasEnded = true
        appearance = [:]; appearanceSeedCount = [:]; face = [:]; records = [:]
        roster = IdentityRoster(entries: [])
    }
}
