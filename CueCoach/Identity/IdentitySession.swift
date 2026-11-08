import Foundation

// Session identity state (research §7.2). RAM only: nothing here is written to disk.

/// Immutable copy handed to a `ShooterIdentifier` off the main actor.
struct IdentitySnapshot: Sendable {
    var roster: IdentityRoster
    var appearanceGallery: [UUID: [Embedding]]
    var faceGallery: [UUID: [Embedding]]
    /// S9 negative signal: per player, the highest similarity a look had that a tap said was *not* them (session only;
    /// a number, never a vector of whoever really shot).
    var appearanceClaimCeiling: [UUID: Double] = [:]
    var faceClaimCeiling: [UUID: Double] = [:]
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
    /// Asked on the card; nobody credited until a tap.
    var unknown = 0
    /// Shots whose shooter was changed by a tap.
    var tapped = 0
    /// Phase 5 metric (research Q16 proposal): fraction right before any tap.
    var correctBeforeTap: Double { total == 0 ? 1 : Double(total - tapped) / Double(total) }
}

@MainActor
final class IdentitySession {
    static let maxExemplars = 8
    /// A held (unbound) shooter vector lives only while its post-shot card can still be tapped: the last N shots.
    static let tapWindow = 4

    private struct Record {
        var original: Attribution
        var current: Attribution
        var sample: Embedding?
        var expectedShooter: UUID?
        /// The gated shooter track's similarities (numbers only), for the S9 negative signal on correction.
        var shooterEvidence: TrackEvidence?
        /// S9: the claim ceiling this shot's correction put on the wrongly chosen player (retracted if tapped back).
        var ceiling: (player: UUID, appearance: Double?, face: Double?)?
        /// Player whose template `sample` was added to by a tap, so a later tap can undo it.
        var boundTo: UUID?
        var seq: Int
    }

    let faceModelID: String
    let bodyModelID: String
    private(set) var roster: IdentityRoster
    private var appearance: [UUID: [Embedding]] = [:]
    private var appearanceSeedCount: [UUID: Int] = [:]
    private var face: [UUID: [Embedding]] = [:]
    private var records: [UUID: Record] = [:]
    private var appearanceCeiling: [UUID: Double] = [:]
    private var faceCeiling: [UUID: Double] = [:]
    /// Players whose stored consent is for older terms or an unusable model: nothing of theirs is loaded or processed
    /// until they agree again (r2 MAJOR).
    private(set) var needsReconsent: Set<UUID> = []
    /// Bumped by every roster/consent change, revoke and end, so an in-flight identification computed from an
    /// older snapshot is discarded and redone.
    private var epoch = 0
    /// In-flight identifications, cancelled by revoke / end so no more frames are embedded after it.
    private var inFlight: [Int: Task<ShooterIdentification, Never>] = [:]
    private var nextFlight = 0
    private var seq = 0
    private(set) var hasEnded = false

    init(players: [(UUID, StoredRecognitionTemplates?)], guests: [UUID] = [], faceModelID: String, bodyModelID: String) {
        self.faceModelID = faceModelID
        self.bodyModelID = bodyModelID
        roster = IdentityRoster(entries: [])
        for (id, t) in players { addPlayer(id: id, stored: t) }
        for g in guests { addGuest(g) }
    }

    // MARK: roster changes (a player joins or leaves mid-session)

    /// Adds a profile (or refreshes it from its stored templates). Consent = stored templates for the current terms and
    /// models; anything older is not loaded at all and the player is flagged for re-consent.
    func addPlayer(id: UUID, stored r: StoredRecognitionTemplates?) {
        guard !hasEnded else { return }
        if roster.contains(id) { removePlayer(id) }
        epoch += 1
        needsReconsent.remove(id)
        if IdentityConsentTerms.needsReconsent(r, faceModelID: faceModelID, bodyModelID: bodyModelID) {
            needsReconsent.formUnion([id])
            roster.entries.append(RosterEntry(playerID: id, consent: .none))
            return
        }
        let consent = RecognitionConsent(faceData: r?.faceEmbedding, appearanceData: r?.appearanceEmbedding)
        roster.entries.append(RosterEntry(playerID: id, consent: consent))
        let t = IdentityTemplates(r, faceModelID: faceModelID, bodyModelID: bodyModelID)
        if consent.face, !t.face.isEmpty { face[id] = t.face }
        if consent.clothes, !t.body.isEmpty {
            let seeds = Array(t.body.prefix(Self.maxExemplars / 2))
            appearance[id] = seeds
            appearanceSeedCount[id] = seeds.count
        }
    }

    func addGuest(_ g: UUID) {
        guard !hasEnded, !roster.contains(g) else { return }
        epoch += 1
        roster.entries.append(RosterEntry(playerID: g, consent: .none, isGuest: true))
    }

    /// A player leaves: their identity data is purged (as on revoke) and they can no longer be picked.
    func removePlayer(_ player: UUID) {
        revoke(player)
        roster.entries.removeAll { $0.playerID == player }
    }

    func snapshot() -> IdentitySnapshot {
        IdentitySnapshot(roster: roster, appearanceGallery: appearance, faceGallery: face,
                         appearanceClaimCeiling: appearanceCeiling, faceClaimCeiling: faceCeiling)
    }

    /// Session-only clothes consent for a guest (no profile, nothing stored). Off unless granted (research Q8).
    func grantGuestClothesConsent(_ guest: UUID) {
        guard let i = roster.entries.firstIndex(where: { $0.playerID == guest && $0.isGuest }) else { return }
        epoch += 1
        roster.entries[i].consent.clothes = true
    }

    /// Tap-to-bind: seeds or extends a clothes-consented player's session template.
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

    /// Removes one learned (non-seed) exemplar again.
    private func unbind(_ player: UUID, appearance e: Embedding) {
        guard let n = e.normalised, var list = appearance[player] else { return }
        let seeds = appearanceSeedCount[player] ?? 0
        if let i = list.indices.last(where: { $0 >= seeds && list[$0] == n }) { list.remove(at: i) }
        appearance[player] = list.isEmpty ? nil : list
    }

    /// Records a result. Never teaches: turn order and `.auto` are guesses, not labels (r2 BLOCKER 1).
    func record(shot: UUID, _ id: ShooterIdentification, expectedShooter: UUID? = nil, teamInTurn: Set<UUID>? = nil) {
        guard !hasEnded else { return }
        let keep = id.shooterAppearance.flatMap { mayHold($0, expected: expectedShooter) ? $0 : nil }
        seq += 1
        let ev = id.attribution.shooterTrackID.flatMap { t in id.evidence.first { $0.trackID == t } }
        records[shot] = Record(original: id.attribution, current: id.attribution, sample: keep, expectedShooter: expectedShooter,
                               shooterEvidence: ev, seq: seq)
        // Close the tap window on older shots: their unbound vectors are dropped now.
        for (k, old) in records where old.sample != nil && old.boundTo == nil && old.seq <= seq - Self.tapWindow {
            var o = old; o.sample = nil; records[k] = o
        }
    }

    func identifyShot(_ shot: UUID, window: StrokeWindow, expectedShooter: UUID, teamInTurn: Set<UUID>?,
                      using identifier: some ShooterIdentifier) async -> Attribution {
        // Any roster/consent change, revoke or end during the off-actor await invalidates the result: redo it from the
        // current snapshot. Revoke/end also cancel the work itself.
        for _ in 0..<3 where !hasEnded {
            let started = epoch
            let snap = snapshot()
            let task = Task.detached { await identifier.identify(window, snapshot: snap, expectedShooter: expectedShooter,
                                                                 teamInTurn: teamInTurn) }
            nextFlight += 1
            let token = nextFlight
            inFlight[token] = task
            let result = await task.value
            inFlight[token] = nil
            guard epoch == started, !hasEnded else { continue }
            record(shot: shot, result, expectedShooter: expectedShooter, teamInTurn: teamInTurn)
            return result.attribution
        }
        // Every analysed snapshot went stale: ask, never a silent turn-order credit (r2 MINOR).
        let fallback = Attribution.unknown(suggested: expectedShooter, confidence: 0, shooterTrackID: nil)
        record(shot: shot, ShooterIdentification(attribution: fallback, shooterAppearance: nil), expectedShooter: expectedShooter,
               teamInTurn: teamInTurn)
        return fallback
    }

    private func cancelInFlight() {
        for t in inFlight.values { t.cancel() }
    }

    func attribution(for shot: UUID) -> Attribution? { records[shot]?.current }

    /// One tap on the post-shot card (any phone). A tap is a human label for a vector that came from the gated
    /// shooter track, so it teaches the tapped player when they consented to clothes, however different the sample
    /// looks from their old template (jacket off, other clothes than at registration). A wrong earlier bind is undone.
    func correct(shot: UUID, to player: UUID) -> Attribution? {
        guard var r = records[shot], roster.contains(player) else { return nil }
        var tapped = Attribution(playerID: player, source: .tap, confidence: 1, shooterTrackID: r.original.shooterTrackID)
        tapped.suggestedPlayerID = r.original.suggestedPlayerID
        r.current = tapped
        if let s = r.sample, let b = r.boundTo, b != player { unbind(b, appearance: s); r.boundTo = nil }
        // S9 negative signal: the look a tap said is not the originally chosen player may not be claimed by them again
        // this session. Tapping back to that player retracts it.
        let chosen = r.original.playerID
        if let w = chosen, w != player, let ev = r.shooterEvidence {
            r.ceiling = (w, ev.appearanceSimilarity[w], ev.faceSimilarity[w])
        } else {
            r.ceiling = nil
        }
        records[shot] = r
        recomputeCeilings()
        // A tap is a human label: it teaches the tapped player when they consented to clothes. While anyone without
        // a clothes template is at the table (guest, no consent), a mis-tap could bind *their* vector, so the sample
        // must also already resemble the tapped player's template (r3 BLOCKER).
        let open = roster.entries.contains { !$0.consent.clothes }
        if let s = r.sample, r.boundTo == nil,
           !open || AppearanceLearning.resemblance(s, appearance[player] ?? []) >= AppearanceLearning.matchFloor,
           bind(player, appearance: s) { r.boundTo = player; epoch += 1 }
        if r.boundTo == nil { r.sample = nil }
        records[shot] = r
        return r.current
    }

    private func recomputeCeilings() {
        var app: [UUID: Double] = [:], fc: [UUID: Double] = [:]
        for r in records.values {
            guard let c = r.ceiling, roster.contains(c.player) else { continue }
            if let s = c.appearance { app[c.player] = max(app[c.player] ?? -1, s) }
            if let s = c.face { fc[c.player] = max(fc[c.player] ?? -1, s) }
        }
        if app != appearanceCeiling || fc != faceCeiling { epoch += 1 }
        appearanceCeiling = app; faceCeiling = fc
    }

    /// Shooter vectors held in RAM, waiting for a tap (not yet part of any template).
    var pendingSampleCount: Int { records.values.filter { $0.sample != nil && $0.boundTo == nil }.count }

    var stats: AttributionStats {
        var s = AttributionStats()
        for r in records.values {
            s.total += 1
            switch r.original.source {
            case .auto: s.auto += 1
            case .turnOrder: s.turnOrder += 1
            case .unknown: s.unknown += 1
            case .tap: break
            }
            if r.current.source == .tap, r.current.playerID != r.original.playerID { s.tapped += 1 }
        }
        return s
    }

    /// `IdentityRevoke` or local delete: purge this player's identity data now.
    func revoke(_ player: UUID) {
        epoch += 1
        cancelInFlight()
        appearance[player] = nil
        appearanceCeiling[player] = nil
        faceCeiling[player] = nil
        appearanceSeedCount[player] = nil
        face[player] = nil
        if let i = roster.entries.firstIndex(where: { $0.playerID == player }) { roster.entries[i].consent = .none }
        for (k, r) in records {
            var r = r
            if r.boundTo == player { r.boundTo = nil }
            if r.ceiling?.player == player { r.ceiling = nil }
            // Drop anything held for this player or no longer justified by anyone else's consent.
            if r.current.playerID == player || r.original.playerID == player { r.sample = nil }
            if let s = r.sample, r.boundTo == nil, !mayHold(s, expected: r.expectedShooter) { r.sample = nil }
            records[k] = r
        }
    }

    /// Session end: drop everything.
    func end() {
        epoch += 1
        cancelInFlight()
        hasEnded = true
        appearance = [:]; appearanceSeedCount = [:]; face = [:]; records = [:]
        appearanceCeiling = [:]; faceCeiling = [:]; needsReconsent = []
        roster = IdentityRoster(entries: [])
    }
}
