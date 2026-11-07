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
    /// Appearance of the shooting track; present only when the attributed player consented to clothes.
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

    private struct Record { var original: Attribution; var current: Attribution; var sample: Embedding? }

    let faceModelID: String
    let bodyModelID: String
    private(set) var roster: IdentityRoster
    private var appearance: [UUID: [Embedding]] = [:]
    private var appearanceSeedCount: [UUID: Int] = [:]
    private var face: [UUID: [Embedding]] = [:]
    private var records: [UUID: Record] = [:]

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

    func record(shot: UUID, _ id: ShooterIdentification) {
        let keep = roster.consent(of: id.attribution.playerID).clothes ? id.shooterAppearance : nil
        records[shot] = Record(original: id.attribution, current: id.attribution, sample: keep)
    }

    func identifyShot(_ shot: UUID, window: StrokeWindow, expectedShooter: UUID, teamInTurn: Set<UUID>?,
                      using identifier: some ShooterIdentifier) async -> Attribution {
        let result = await identifier.identify(window, snapshot: snapshot(), expectedShooter: expectedShooter,
                                               teamInTurn: teamInTurn)
        record(shot: shot, result)
        return result.attribution
    }

    func attribution(for shot: UUID) -> Attribution? { records[shot]?.current }

    /// One tap on the post-shot card (any phone). Becomes session training signal for consented players only.
    func correct(shot: UUID, to player: UUID) -> Attribution? {
        guard var r = records[shot], roster.contains(player) else { return nil }
        r.current = Attribution(playerID: player, source: .tap, confidence: 1, shooterTrackID: r.original.shooterTrackID)
        if let s = r.sample { bind(player, appearance: s) }
        r.sample = nil
        records[shot] = r
        return r.current
    }

    var pendingSampleCount: Int { records.values.filter { $0.sample != nil }.count }

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
        appearance[player] = nil
        appearanceSeedCount[player] = nil
        face[player] = nil
        if let i = roster.entries.firstIndex(where: { $0.playerID == player }) { roster.entries[i].consent = .none }
        for (k, r) in records where r.current.playerID == player || r.original.playerID == player {
            records[k]?.sample = nil
        }
    }

    /// Session end: drop everything.
    func end() {
        appearance = [:]; appearanceSeedCount = [:]; face = [:]; records = [:]
        roster = IdentityRoster(entries: [])
    }
}
