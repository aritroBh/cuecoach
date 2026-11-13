import Foundation
import Rules
import Sync

/// Tunables. Every number marked *assumption* in mesh-identity.md is here so device tests can tune it.
struct MeshConfig: Sendable {
    var heartbeatInterval = 0.25
    /// Silence after which a peer counts as dead (*assumption*; tune from measured AWDL gaps, §2.5).
    var failTimeout = 1.5
    /// Lobby: how long a fresh phone listens for an existing host before electing.
    var discoveryWindow = 1.0
    /// New host waits this long for survivors' log tails before resuming (normally all reply in ms).
    var collectTimeout = 0.5
    /// MPC limit and the 4v4 maximum.
    var maxPeers = 8
    var order: ElectionOrder = .default
    var supportedMajors: [Int] = ProtocolVersion.supportedMajors
    var voteDeadline = 20.0
    var clipOfferWindow = 0.5
    var pingBurst = 16
    var pingBurstSpacing = 0.02
    var pingInterval = 1.0
    /// Log entries per message, so catch-up stays under `MeshCodec.maxMessageBytes`.
    var logBatch = 8
    /// Which table's session this phone joins: the lobby's glyph + colour pick (mesh-identity.md §2.3).
    /// Phones with different tags never connect (transport) and drop each other's envelopes (node).
    var sessionTag: UInt16 = 0
    /// Own clips kept for the host to pull (≈ 4–10 MB each). Oldest are evicted first.
    var maxStoredClips = 3
    /// Session-only profile summary (SPEC §5.7) size cap.
    var maxProfileBytes = 64 * 1024
    /// Unacknowledged clip chunks are resent after this much transmittable time with no ack.
    var clipAckTimeout = 2.0
    /// Whole-clip retries after a failed final hash before the host gives up on that view.
    var clipRetries = 2
    /// New host: after `collectTimeout`, keeps waiting for a majority of the old roster's log tails;
    /// gives up waiting only after this much longer (a survivor alive but silent).
    var collectHardTimeout = 3.0
}

enum MeshRole: Hashable, Sendable {
    case discovering
    case host
    case client(host: PeerID)
}

/// What the app hears from the mesh. Never shown as text while aiming; the app maps these to visuals.
enum MeshUpdate: Hashable, Sendable {
    case roleChanged(MeshRole, term: UInt64)
    case rosterChanged([PeerID])
    case logChanged(lastSeq: UInt64, commitSeq: UInt64)
    case tableState(from: PeerID, TableStateFrame)
    case calibration(from: PeerID, CalibrationReport)
    case phase(MeshPhase)
    case ruleVoteOpened(voteID: UInt64)
    case ruleVoteClosed(RuleSetID)
    case clipReceived(shotID: UUID, from: PeerID, data: Data)
    case rejected(RejectReason)
    /// Session-only profile summary from a peer (SPEC §5.7). Opaque to the mesh; the identity module owns it.
    case profile(from: PeerID, Data)
    /// Plan 013a: this phone became, or stopped being, an island (no host, or hosting without a majority).
    case island(Bool)
    /// Plan 013a: one of this phone's own settles was answered by another entry for the same stroke (never logged
    /// under its own id): the link counts it as confirmed.
    case settleAbsorbed(shotID: UUID)
}

struct Outbound: Hashable, Sendable {
    var to: [PeerID]
    var message: MeshMessage
    var channel: MeshChannel { message.defaultChannel }
    var lane: OutboundQueue.Lane {
        switch message {
        case .tableState: .realtime
        case .clipChunk: .bulk
        default: .control
        }
    }
}

struct MeshStep: Sendable {
    var outbound: [Outbound] = []
    var updates: [MeshUpdate] = []
}

/// The whole session protocol as a pure, deterministic state machine: no I/O, no clock, no threads.
/// Inputs: transport events, decoded envelopes, ticks, app calls — each with the caller's local time in
/// seconds. Outputs: messages to send and app updates. `MeshSession` drives it with MPC and a real clock;
/// tests drive it with `SimNetwork`.
///
/// Model (mesh-identity.md §2.4–2.5, adapted to MPC's full mesh):
/// - Star for game state: the host is the only log writer. Clients replicate and ack; committed = acked by
///   a majority of the roster.
/// - Everyone sends liveness every `heartbeatInterval`; `FailureDetector` declares death after `failTimeout`.
/// - On host loss every survivor ranks roster ∩ alive the same way; the top one claims `term + 1`,
///   collects survivors' log tails (so no committed entry is lost), then resumes. Higher term wins;
///   equal-term conflicts go to the better-ranked claimant.
/// - A sitting host keeps hosting while alive (hysteresis).
struct MeshNode: Sendable {
    let id: PeerID
    private(set) var status: PeerStatus
    let config: MeshConfig
    /// Same for every phone with the same `config.sessionTag`; envelopes with another ID are dropped.
    let sessionID: UUID

    private(set) var role: MeshRole = .discovering
    private(set) var term: UInt64 = 0
    private(set) var hostID: PeerID?
    /// Host's admitted members, including the host.
    private(set) var roster: [PeerID] = []
    private(set) var log: [LogEntry] = []
    private(set) var commitSeq: UInt64 = 0
    private(set) var phase: MeshPhase = .lobby
    private(set) var clock = ClockSyncEstimator()
    private(set) var ignoredMessages = 0
    private(set) var rejected: RejectReason?
    /// Peers' session-only profile summaries. Never persisted.
    private(set) var profiles: [PeerID: Data] = [:]
    /// After `leave` the node is inert.
    private(set) var left = false

    private var statuses: [PeerID: PeerStatus] = [:]
    private var connected: Set<PeerID> = []
    private var detector: FailureDetector
    private var startedAt = 0.0
    private var everJoined = false
    private var lastLiveness = -Double.infinity
    private var envelopeSeq: UInt64 = 0

    // client
    private var synced = false
    private var lastTailRequest = -Double.infinity
    private var pingsLeftInBurst = 0
    private var nextPing = 0.0
    private var openVoteID: UInt64?
    private var clipSender: ClipSender?
    private var localClips: [UUID: Data] = [:]
    private var localClipOrder: [UUID] = []
    private var clipProgressAt = 0.0
    private var myProfile: Data?
    private var profileSentTo: Set<PeerID> = []

    // host
    private var acks: [PeerID: UInt64] = [:]
    private var collecting: Set<PeerID>?
    private var collectDeadline = 0.0
    /// Reports (me + survivors' hellos) needed before resuming: a majority of the old roster, so the
    /// collected tails always include a holder of every committed entry.
    private var collectNeed = 0
    private var collectReports = 0
    /// Survivors' full logs, gathered while collecting.
    private var tails: [PeerID: [LogEntry]] = [:]
    /// Roster size before the last host loss (incl. the lost host), set by `hostLost`.
    private var lostRosterSize = 0
    /// Commit denominator. Silent drops don't shrink it unless a majority of it is still here, so an
    /// isolated minority host can't commit (graceful leaves do shrink it).
    private var quorumBase = 1
    private var clipAttempts: [UUID: Int] = [:]
    private var pendingHellos: [PeerID] = []
    private var pendingAppends: [GameEvent] = []
    private var voteID: UInt64 = 0
    private var ballots: [PeerID: RuleSetID] = [:]
    private var voteDeadline: Double?
    private var clipOffers: [UUID: [PeerID: Double]] = [:]
    private var clipOfferDeadline: [UUID: Double] = [:]
    private var clipReceivers: [UUID: (from: PeerID, receiver: ClipReceiver)] = [:]

    // islands (plan 013a, §2.5)
    /// The game clock as this phone last knew it while a client (its fit to that host + that host's game offset),
    /// frozen when the host was lost. nil = this phone's own clock is the game clock (it hosted first).
    private var gameFit: (clock: ClockSyncEstimator, offset: Int64)?
    /// Client: the host's `Heartbeat.gameOffset`; nil = unknown (the host has no game clock, or no heartbeat yet).
    private var hostGameOffset: Int64?
    /// This phone's own settles that no committed entry answers yet, with the stroke on this phone's clock (ns).
    private var kept: [(event: GameEvent, stroke: Int64)] = []
    /// Every phone seen in a roster since joining, minus those that left gracefully: the island denominator.
    private var gameMembers: Set<PeerID> = []
    private var departed: Set<PeerID> = []
    /// Host: island logs being received, by sender.
    private var islandIn: [PeerID: (commitSeq: UInt64, entries: [LogEntry])] = [:]
    /// Host: complete island logs, merged when their sender's Hello admits it (or after collecting).
    private var pendingIslands: [PeerID: Island] = [:]
    private var reportedIsland = false
    /// This phone has been a client: without a clock fit its own clock is not the game clock.
    private var everClient = false
    /// Host: bumped on every rewrite of existing entries; new entries carry it, acks name it.
    private var logEpoch: UInt64 = 0
    /// Bumped whenever the log's content changes without its counters saying so (rewrites, welcomes).
    private var logVersion = 0

    private var step = MeshStep()

    init(id: PeerID = PeerID(), status: PeerStatus, config: MeshConfig = MeshConfig()) {
        self.id = id
        self.status = status
        self.config = config
        detector = FailureDetector(timeout: config.failTimeout)
        statuses[id] = status
        sessionID = Self.sessionID(tag: config.sessionTag)
    }

    static func sessionID(tag: UInt16) -> UUID {
        UUID(uuid: (0x43, 0x55, 0x45, 0x53, 0x45, 0x53, 0x53, 0x4E, 0, 0, 0, 0, 0, 0, UInt8(tag >> 8), UInt8(tag & 0xFF)))
    }

    var lastSeq: UInt64 { log.last?.seq ?? 0 }
    var isHost: Bool { role == .host }
    var storedClipCount: Int { localClips.count }
    /// Plan 013a: after first joining, discovering, or hosting a roster that is not a strict majority of the game's
    /// members (every phone seen in a roster, minus graceful leaves). A client is never an island.
    var isIsland: Bool {
        guard everJoined, rejected == nil, !left else { return false }
        switch role {
        case .client: return false
        case .discovering: return true
        case .host: return roster.count * 2 <= gameMembers.union(roster).count
        }
    }

    // MARK: - Inputs

    mutating func start(now: Double) -> MeshStep {
        startedAt = now
        return flush()
    }

    mutating func peerConnected(_ p: PeerID, now: Double) -> MeshStep {
        guard rejected == nil, !left else { return flush() }
        connected.insert(p)
        detector.heard(p, at: now)
        send(.peerStatus(status), to: [p])
        if isHost { send(heartbeat(now: now), to: [p]) }
        return flush()
    }

    mutating func peerDisconnected(_ p: PeerID, now: Double) -> MeshStep {
        disconnect(p, graceful: false, now: now)
        return flush()
    }

    private mutating func disconnect(_ p: PeerID, graceful: Bool, now: Double) {
        connected.remove(p)
        detector.forget(p)
        if graceful { departed.insert(p); gameMembers.remove(p) }
        guard rejected == nil, !left else { return }
        if isHost {
            dropMembers([p], graceful: graceful, now: now)
        } else if p == hostID {
            hostLost(now: now)
        }
    }

    mutating func updateStatus(_ s: PeerStatus, now: Double) -> MeshStep {
        status = s
        statuses[id] = s
        send(.peerStatus(s), to: Array(connected))
        return flush()
    }

    /// Envelope for an outbound message (the transport encodes it).
    mutating func envelope(_ m: MeshMessage, now: Double) -> MeshEnvelope {
        envelopeSeq += 1
        // Frames always use this build's major so any peer can decode the Hello/Reject exchange;
        // compatibility is negotiated from `Hello.supportedMajors`.
        return MeshEnvelope(version: .current, sessionID: sessionID, sender: id, seq: envelopeSeq, sentAt: Self.ns(now), message: m)
    }

    mutating func handle(_ env: MeshEnvelope, now: Double) -> MeshStep {
        if case .unknown = env.message { ignoredMessages += 1; return flush() }
        guard rejected == nil, !left, env.sender != id else { return flush() }
        // Another table's session (or a forged sender) — never mix games.
        guard env.sessionID == sessionID else { ignoredMessages += 1; return flush() }
        let from = env.sender
        detector.heard(from, at: now)
        switch env.message {
        case .hello(let h): onHello(h, from: from, now: now)
        case .welcome(let w): onWelcome(w, from: from, now: now)
        case .reject(let r): onReject(r, from: from)
        case .leave: disconnect(from, graceful: true, now: now)
        case .heartbeat(let hb): onHeartbeat(hb, from: from, now: now)
        case .peerStatus(let s): statuses[from] = s
        case .roster(let r): onRoster(r, from: from)
        case .hostClaim(let c): onHostClaim(c, from: from, now: now)
        case .timePing(let p):
            let t = Self.ns(now)
            send(.timePong(TimePong(t0: p.t0, t1: t, t2: t)), to: [from])
        case .timePong(let p):
            if from == hostID, !isHost { clock.add(ClockSample(t0: p.t0, t1: p.t1, t2: p.t2, t3: Self.ns(now))) }
        case .ruleVoteOpen(let v):
            if from == hostID { openVoteID = v.voteID; step.updates.append(.ruleVoteOpened(voteID: v.voteID)) }
        case .ruleBallot(let b):
            if isHost, b.voteID == voteID, voteDeadline != nil, roster.contains(from) {
                ballots[from] = b.choice
                closeVoteIfDone(now: now)
            }
        case .ruleVoteResult(let r):
            if from == hostID { openVoteID = nil; step.updates.append(.ruleVoteClosed(r.winner)) }
        case .tableState(let f):
            if isHost, roster.contains(from) { step.updates.append(.tableState(from: from, f)) }
        case .proposal(let e):
            if isHost, roster.contains(from) { _ = append(e, now: now, flushing: false) }
        case .logEntries(let es): onLogEntries(es, from: from, now: now)
        case .logAck(let a):
            // Plan 013a: an ack counts only for the version of the entry I hold now (an island merge may have
            // replaced it since the client acked).
            if isHost, a.term == term, roster.contains(from), a.upTo <= lastSeq,
               a.upTo == 0 || log[Int(a.upTo) - 1].epoch == a.epoch {
                acks[from] = max(acks[from] ?? 0, a.upTo)
                advanceCommit()
            }
        case .logTailRequest(let r):
            if isHost, roster.contains(from), collecting == nil { sendLog(from: r.fromSeq, to: from) }
        case .calibration(let c):
            if isHost, roster.contains(from) { step.updates.append(.calibration(from: from, c)) }
        case .phaseChange(let p):
            if from == hostID, !isHost, p != phase { phase = p; step.updates.append(.phase(p)) }
        case .clipOffer(let o):
            if isHost, roster.contains(from) { registerOffer(o.shotID, from: from, score: o.viewScore, now: now) }
        case .clipRequest(let r):
            if from == hostID, let d = localClips[r.shotID], !d.isEmpty {
                clipSender = ClipSender(shotID: r.shotID, data: d)
                clipProgressAt = now
                pumpClip()
            }
        case .clipChunk(let c):
            if isHost, var entry = clipReceivers[c.shotID], entry.from == from {
                let ack = entry.receiver.receive(c)
                clipReceivers[c.shotID] = entry
                send(.clipChunkAck(ack), to: [from])
            }
        case .clipChunkAck(let a):
            if from == hostID, clipSender?.shotID == a.shotID {
                clipSender?.handle(a)
                clipProgressAt = now
                pumpClip()
            }
        case .clipComplete(let c):
            if isHost, let entry = clipReceivers[c.shotID], entry.from == from {
                if entry.receiver.finish(c), let d = entry.receiver.assembled {
                    clipReceivers[c.shotID] = nil
                    clipAttempts[c.shotID] = nil
                    step.updates.append(.clipReceived(shotID: c.shotID, from: from, data: d))
                } else if (clipAttempts[c.shotID] ?? 0) < config.clipRetries {
                    // Whole-clip hash failed: ask again from scratch, a bounded number of times.
                    clipAttempts[c.shotID, default: 0] += 1
                    clipReceivers[c.shotID] = (from, ClipReceiver(shotID: c.shotID))
                    send(.clipRequest(ClipRequest(shotID: c.shotID)), to: [from])
                } else {
                    clipReceivers[c.shotID] = nil
                    clipAttempts[c.shotID] = nil
                }
            }
        case .profile(let p):
            if p.summary.count <= config.maxProfileBytes, profiles[from] != p.summary {
                profiles[from] = p.summary
                step.updates.append(.profile(from: from, p.summary))
            }
        case .islandLog(let l): onIslandLog(l, from: from, now: now)
        case .unknown: break
        }
        return flush()
    }

    mutating func tick(now: Double) -> MeshStep {
        guard rejected == nil, !left else { return flush() }
        if now - lastLiveness >= config.heartbeatInterval {
            lastLiveness = now
            if isHost { send(heartbeat(now: now), to: Array(connected)) }
            send(.peerStatus(status), to: Array(connected))
        }
        switch role {
        case .discovering:
            if everJoined || now - startedAt >= config.discoveryWindow { claimIfTop(now: now) }
        case .client(let h):
            if !detector.isAlive(h, now: now) {
                hostLost(now: now)
            } else {
                clientTick(now: now)
            }
        case .host:
            hostTick(now: now)
        }
        return flush()
    }

    // MARK: - App calls

    /// Host appends; a client forwards a proposal to the host.
    mutating func append(_ e: GameEvent, now: Double) -> MeshStep { append(e, now: now, flushing: true) }

    /// Plan 013a: this phone's own settle (`.shot` / `.shotLost`) with its stroke time on this phone's clock (s).
    /// The host stamps the stroke on the game clock and appends; any other phone keeps it until a committed entry
    /// answers the same stroke, and re-runs it as a new host or sends it on adopting one.
    mutating func settled(_ e: GameEvent, strokeAt: Double, now: Double) -> MeshStep {
        guard rejected == nil, !left else { return flush() }
        let stroke = Self.ns(strokeAt)
        let stamped = Self.stamped(e, gameNs(fromLocal: stroke))
        if isHost && collecting == nil {
            // A late view of a stroke an inherited entry (an earlier host's) already answers is not new: e.g. one
            // settled after this phone was promoted. My own appends this term never block the next one.
            let answered = log.contains { $0.term < term && IslandHeal.matches(stamped, $0.event) }
            if !answered { _ = append(stamped, now: now, flushing: false) }
        } else if !committedEntries.contains(where: { IslandHeal.matches(stamped, $0.event) }) {
            kept.append((e, stroke))
            if kept.count > 16 { kept.removeFirst() }
        }
        return flush()
    }

    private var committedEntries: ArraySlice<LogEntry> { log.prefix { $0.seq <= commitSeq } }

    mutating func openRuleVote(now: Double) -> MeshStep {
        guard isHost else { return flush() }
        voteID += 1
        ballots = [:]
        voteDeadline = now + config.voteDeadline
        send(.ruleVoteOpen(RuleVoteOpen(voteID: voteID, deadline: config.voteDeadline)), to: clients)
        step.updates.append(.ruleVoteOpened(voteID: voteID))
        return flush()
    }

    mutating func castBallot(_ choice: RuleSetID, now: Double) -> MeshStep {
        if isHost {
            if voteDeadline != nil { ballots[id] = choice; closeVoteIfDone(now: now) }
        } else if let h = hostID, let v = openVoteID {
            send(.ruleBallot(RuleBallot(voteID: v, choice: choice)), to: [h])
        }
        return flush()
    }

    mutating func setPhase(_ p: MeshPhase, now: Double) -> MeshStep {
        guard isHost else { return flush() }
        if p != phase { phase = p; step.updates.append(.phase(p)) }
        send(.phaseChange(p), to: clients)
        return flush()
    }

    /// Detections in this phone's capture clock; converted to host time before sending.
    mutating func sendTableState(_ f: TableStateFrame, now: Double) -> MeshStep {
        if isHost {
            step.updates.append(.tableState(from: id, f))
        } else if let h = hostID, let t = clock.hostTime(fromLocal: f.captureTime) {
            // No clock fit yet → the host couldn't place this frame in time; drop it rather than guess.
            var g = f
            g.captureTime = t
            send(.tableState(g), to: [h])
        }
        return flush()
    }

    mutating func sendCalibration(_ r: CalibrationReport, now: Double) -> MeshStep {
        if isHost { step.updates.append(.calibration(from: id, r)) } else if let h = hostID { send(.calibration(r), to: [h]) }
        return flush()
    }

    /// Offer this phone's view of a shot. The host pulls the best one after balls settle (D3).
    mutating func offerClip(shotID: UUID, data: Data, viewScore: Double, now: Double) -> MeshStep {
        guard !data.isEmpty else { return flush() }   // failed capture: nothing to offer
        storeClip(shotID, data)
        if isHost {
            registerOffer(shotID, from: id, score: viewScore, now: now)
        } else if let h = hostID {
            send(.clipOffer(ClipOffer(shotID: shotID, viewScore: viewScore, byteSize: data.count)), to: [h])
        }
        return flush()
    }

    mutating func leave(now: Double) -> MeshStep {
        guard !left else { return flush() }
        send(.leave, to: Array(connected))
        left = true
        return flush()
    }

    /// Share this player's profile summary with the session's members only (SPEC §5.7). Opaque bytes:
    /// what goes in (and whether an embedding may, given join authentication) is the identity module's call.
    mutating func shareProfile(_ summary: Data, now: Double) -> MeshStep {
        guard summary.count <= config.maxProfileBytes else { return flush() }
        myProfile = summary
        profileSentTo = []
        sendProfileToNewMembers()
        return flush()
    }

    private mutating func sendProfileToNewMembers() {
        guard let p = myProfile else { return }
        profileSentTo.formIntersection(roster)
        let fresh = roster.filter { $0 != id && !profileSentTo.contains($0) }
        guard !fresh.isEmpty else { return }
        profileSentTo.formUnion(fresh)
        send(.profile(ProfileShare(summary: p)), to: fresh)
    }

    private mutating func storeClip(_ shot: UUID, _ data: Data) {
        if localClips.updateValue(data, forKey: shot) == nil { localClipOrder.append(shot) }
        while localClipOrder.count > max(1, config.maxStoredClips) {
            localClips[localClipOrder.removeFirst()] = nil
        }
    }

    private mutating func releaseClip(_ shot: UUID) {
        localClips[shot] = nil
        localClipOrder.removeAll { $0 == shot }
    }

    // MARK: - Election + migration

    private func heartbeat(now: Double) -> MeshMessage {
        let t = Self.ns(now)
        let game = gameNs(fromLocal: t)
        return .heartbeat(Heartbeat(term: term, host: id, lastSeq: lastSeq, commitSeq: commitSeq, phase: phase,
                                    gameOffset: gameFit == nil ? nil : game.map { $0 - t },
                                    gameTimeUnknown: game == nil ? true : nil))
    }

    private var clients: [PeerID] { roster.filter { $0 != id } }

    /// Who may host if the current host is gone: roster ∩ alive (lobby: alive connected peers) ∪ me.
    private func candidates(now: Double, excluding gone: PeerID?) -> [PeerID: PeerStatus] {
        let pool = everJoined ? Set(roster) : connected
        var c: [PeerID: PeerStatus] = [id: status]
        for p in pool where p != id && p != gone && detector.isAlive(p, now: now) {
            if let s = statuses[p] { c[p] = s }
        }
        return c
    }

    private mutating func hostLost(now: Double) {
        let gone = hostID
        // Keep stamping strokes on the game clock: freeze the last fit to the lost host (§2.5, drifts ≈ 3 ms/min).
        if clock.estimate != nil, let offset = hostGameOffset { gameFit = (clock, offset) }
        lostRosterSize = roster.count
        if let gone { roster.removeAll { $0 == gone }; detector.forget(gone) }
        hostID = nil
        if role != .discovering { role = .discovering; step.updates.append(.roleChanged(.discovering, term: term)) }
        openVoteID = nil
        clipSender = nil
        claimIfTop(now: now, excluding: gone)
    }

    private mutating func claimIfTop(now: Double, excluding gone: PeerID? = nil) {
        let c = candidates(now: now, excluding: gone)
        guard HostElection.elect(c, order: config.order) == id else { return }
        term += 1
        role = .host
        hostID = id
        acks = [:]
        voteDeadline = nil
        clipOffers = [:]
        clipOfferDeadline = [:]
        clipReceivers = [:]
        let priorMembers = everJoined ? max(roster.count, 1) : 1
        roster = [id] + c.keys.filter { $0 != id && everJoined }.sorted()
        // A claim by a minority island keeps the old roster as its commit denominator.
        quorumBase = max(roster.count, priorMembers)
        collectNeed = everJoined ? lostRosterSize / 2 + 1 : 0
        collectReports = 1
        tails = [:]
        lostRosterSize = 0
        everJoined = true
        let survivors = Set(roster).subtracting([id])
        collecting = survivors.isEmpty ? nil : survivors
        collectDeadline = now + config.collectTimeout
        send(.hostClaim(HostClaim(term: term, lastSeq: lastSeq)), to: Array(connected))
        send(heartbeat(now: now), to: Array(connected))
        step.updates.append(.roleChanged(.host, term: term))
        broadcastRoster()
        if collecting == nil { finishCollecting(now: now) }
    }

    /// Accepting `host` at `newTerm` (from a heartbeat, claim or welcome).
    private mutating func adopt(host h: PeerID, term newTerm: UInt64, now: Double) {
        let wasHost = isHost
        // Plan 013a: my whole log with its commit point (the new host keeps what I hold committed and merges my tail)
        // and my own unlogged settles, on the game clock as I know it now (before the clock resets for the new host).
        let islandLog = log, islandCommit = commitSeq
        let settles = keptSettles()   // kept until seen committed: the new host may die before merging them
        everClient = true
        term = newTerm
        hostID = h
        role = .client(host: h)
        synced = false
        everJoined = true
        collecting = nil
        pendingHellos = []
        voteDeadline = nil
        clipReceivers = [:]
        clipSender = nil
        openVoteID = nil
        tails = [:]
        clipAttempts = [:]
        if wasHost { pendingAppends.forEach { send(.proposal($0), to: [h]) }; pendingAppends = [] }
        clock.reset()
        pingsLeftInBurst = config.pingBurst
        nextPing = now
        // Give the new host my whole log (ordered before the hello on the reliable channel): it was elected
        // by device, not by log, so it may lack entries I know are committed. It keeps the most up-to-date
        // log among a majority, then welcomes everyone with it.
        var i = 0
        while i < log.count {
            send(.logEntries(Array(log[i..<min(i + config.logBatch, log.count)])), to: [h])
            i += config.logBatch
        }
        if !islandLog.isEmpty || !settles.isEmpty {
            var j = 0
            repeat {
                let batch = Array(islandLog[j..<min(j + config.logBatch, islandLog.count)])
                j += config.logBatch
                let last = j >= islandLog.count
                send(.islandLog(IslandLog(commitSeq: islandCommit, entries: batch, settles: last ? settles : [], last: last)),
                     to: [h])
            } while j < islandLog.count
        }
        hostGameOffset = nil
        send(.hello(hello), to: [h])
        step.updates.append(.roleChanged(role, term: term))
    }

    private var hello: Hello {
        Hello(deviceClass: status.deviceClass, batteryPercent: status.batteryPercent, onPower: status.onPower,
              supportedMajors: config.supportedMajors)
    }

    private func wins(term t: UInt64, claimant: PeerID) -> Bool {
        if role == .discovering && hostID == nil && t >= term && term == 0 { return true }
        return HostElection.claimWins(term: t, claimant: claimant, over: term, incumbent: hostID,
                                      statuses: statuses, order: config.order)
    }

    private mutating func onHeartbeat(_ hb: Heartbeat, from: PeerID, now: Double) {
        guard hb.host == from else { return }
        if from == hostID, hb.term == term {
            guard !isHost else { return }
            hostGameOffset = hb.gameTimeUnknown == true ? nil : (hb.gameOffset ?? 0)
            if synced {
                commitSeq = max(commitSeq, min(hb.commitSeq, lastSeq))
                if hb.lastSeq > lastSeq { requestTail(now: now) }
            }
            if hb.phase != phase { phase = hb.phase; step.updates.append(.phase(hb.phase)) }
            return
        }
        if wins(term: hb.term, claimant: from) {
            adopt(host: from, term: hb.term, now: now)
            hostGameOffset = hb.gameTimeUnknown == true ? nil : (hb.gameOffset ?? 0)
        } else if isHost {
            send(heartbeat(now: now), to: [from])          // the stale side will step down
        }
    }

    private mutating func onHostClaim(_ c: HostClaim, from: PeerID, now: Double) {
        if wins(term: c.term, claimant: from) {
            adopt(host: from, term: c.term, now: now)
        } else if isHost {
            send(heartbeat(now: now), to: [from])
        }
    }

    private mutating func onWelcome(_ w: Welcome, from: PeerID, now: Double) {
        guard w.host == from else { return }
        if from != hostID || w.term != term {
            guard wins(term: w.term, claimant: from) else { return }
            adopt(host: from, term: w.term, now: now)
        }
        if log != w.log { logVersion += 1 }
        log = w.log
        synced = true
        commitSeq = min(w.commitSeq, lastSeq)
        if roster != w.roster { roster = w.roster; step.updates.append(.rosterChanged(w.roster)) }
        sendProfileToNewMembers()
        sendAck()
    }

    private mutating func onReject(_ r: RejectReason, from: PeerID) {
        guard from == hostID || hostID == nil else { return }
        rejected = r
        role = .discovering
        hostID = nil
        step.updates.append(.rejected(r))
    }

    private mutating func onRoster(_ r: RosterUpdate, from: PeerID) {
        guard from == hostID, r.term == term, !isHost else { return }
        for m in r.members where m.peer != id { statuses[m.peer] = m.status }
        let members = r.members.map(\.peer)
        if members != roster { roster = members; step.updates.append(.rosterChanged(members)) }
        sendProfileToNewMembers()
    }

    // MARK: - Host

    private mutating func onHello(_ h: Hello, from: PeerID, now: Double) {
        guard isHost else { return }
        guard let major = ProtocolVersion.negotiate(local: config.supportedMajors, remote: h.supportedMajors) else {
            let tooOld = (h.supportedMajors.max() ?? 0) < (config.supportedMajors.min() ?? 0)
            send(.reject(tooOld ? .versionTooOld : .versionTooNew), to: [from])
            return
        }
        _ = major
        if !roster.contains(from) {
            guard roster.count < config.maxPeers else { send(.reject(.sessionFull), to: [from]); return }
            roster.append(from)
            quorumBase = max(quorumBase, roster.count)
        }
        statuses[from] = PeerStatus(deviceClass: h.deviceClass, batteryPercent: h.batteryPercent, onPower: h.onPower)
        if collecting == nil, let island = pendingIslands.removeValue(forKey: from) {
            heal(island)   // after admitting the sender: what the merge adds commits only once it holds it too
        }
        if var c = collecting {
            if c.remove(from) != nil { collectReports += 1 }
            collecting = c
            if !pendingHellos.contains(from) { pendingHellos.append(from) }
            if c.isEmpty { finishCollecting(now: now) }
        } else {
            welcome(from)
            broadcastRoster()
        }
    }

    private mutating func welcome(_ p: PeerID) {
        let first = Array(log.prefix(config.logBatch))
        send(.welcome(Welcome(term: term, host: id, roster: roster, log: first, commitSeq: commitSeq)), to: [p])
        if log.count > first.count { sendLog(from: (first.last?.seq ?? 0) + 1, to: p) }
        send(.phaseChange(phase), to: [p])
        if voteDeadline != nil { send(.ruleVoteOpen(RuleVoteOpen(voteID: voteID, deadline: config.voteDeadline)), to: [p]) }
    }

    private mutating func sendLog(from seq: UInt64, to p: PeerID) {
        let tail = log.filter { $0.seq >= seq }
        var i = 0
        while i < tail.count {
            send(.logEntries(Array(tail[i..<min(i + config.logBatch, tail.count)])), to: [p])
            i += config.logBatch
        }
    }

    private mutating func finishCollecting(now: Double) {
        collecting = nil
        // Most up-to-date log (last term, then length) among me and the survivors' complete tails.
        func rank(_ l: [LogEntry]) -> (UInt64, UInt64) { (l.last?.term ?? 0, l.last?.seq ?? 0) }
        for t in tails.values {
            let sorted = t.sorted { $0.seq < $1.seq }
            guard sorted.enumerated().allSatisfy({ $0.element.seq == UInt64($0.offset + 1) }),
                  sorted.allSatisfy({ $0.term < term }) else { continue }
            if rank(sorted) > rank(log) { log = sorted }
        }
        tails = [:]
        // Plan 013a: re-run the shot in flight from my own settles, and merge island logs that came in meanwhile.
        logEpoch = max(logEpoch, log.compactMap(\.epoch).max() ?? 0)   // epochs stay monotonic across host changes
        heal(Island(commitSeq: commitSeq, entries: log, settles: keptSettles()))
        kept = []
        for p in pendingHellos { if let island = pendingIslands.removeValue(forKey: p) { heal(island) } }
        let hellos = pendingHellos
        pendingHellos = []
        for p in hellos { welcome(p) }
        broadcastRoster()
        let appends = pendingAppends
        pendingAppends = []
        for e in appends { _ = append(e, now: now, flushing: false) }
        advanceCommit()
    }

    private mutating func append(_ e: GameEvent, now: Double, flushing: Bool) -> MeshStep {
        if isHost {
            if collecting != nil {
                pendingAppends.append(e)
            } else {
                let entry = LogEntry(seq: lastSeq + 1, term: term, event: e, epoch: logEpoch == 0 ? nil : logEpoch)
                log.append(entry)
                send(.logEntries([entry]), to: clients)
                advanceCommit()
            }
        } else if let h = hostID {
            send(.proposal(e), to: [h])
        }
        return flushing ? flush() : MeshStep()
    }

    private mutating func onLogEntries(_ es: [LogEntry], from: PeerID, now: Double) {
        let sorted = es.sorted { $0.seq < $1.seq }
        if isHost {
            // Only the host writes. The one exception: a survivor's log while this new host collects
            // (merged in `finishCollecting`). Everyone else — strangers, rejected phones, a stepped-down
            // host from a split — is ignored.
            if collecting?.contains(from) == true {
                tails[from, default: []] += sorted
            } else {
                ignoredMessages += 1
            }
            return
        }
        guard from == hostID, synced, !sorted.isEmpty else { return }
        for e in sorted where e.seq >= 1 {
            if e.seq <= lastSeq {
                let i = Int(e.seq - 1)
                // Same entry again (duplicate / stale batch): keep what I have. A different one: the host's
                // log wins from here on.
                if log[i] != e {
                    log.removeSubrange(i...)
                    log.append(e)
                    commitSeq = min(commitSeq, UInt64(i))   // a replaced entry was never committed (plan 013a)
                    logVersion += 1
                }
            } else if e.seq == lastSeq + 1 {
                log.append(e)
            } else {
                requestTail(now: now)
                break
            }
        }
        commitSeq = min(commitSeq, lastSeq)
        sendAck()
    }

    private mutating func sendAck() {
        guard let h = hostID, !isHost else { return }
        send(.logAck(LogAck(term: term, upTo: lastSeq, epoch: log.last?.epoch)), to: [h])
    }

    private mutating func requestTail(now: Double) {
        guard let h = hostID, now - lastTailRequest >= 0.5 else { return }
        lastTailRequest = now
        send(.logTailRequest(LogTailRequest(fromSeq: lastSeq + 1)), to: [h])
    }

    private mutating func advanceCommit() {
        guard isHost, !roster.isEmpty else { return }
        let base = max(quorumBase, roster.count)
        var acked = roster.map { $0 == id ? lastSeq : (acks[$0] ?? 0) }
        acked += Array(repeating: 0, count: base - acked.count)   // missing members count as "not acked"
        acked.sort(by: >)
        commitSeq = max(commitSeq, acked[base / 2])
    }

    private mutating func dropMembers(_ gone: [PeerID], graceful: Bool = false, now: Double) {
        let before = roster
        let me = id
        roster.removeAll { gone.contains($0) && $0 != me }
        for p in gone { acks[p] = nil; ballots[p] = nil }
        guard roster != before else { return }
        let left = before.count - roster.count
        if graceful {
            quorumBase = max(roster.count, quorumBase - left)
        } else if roster.count >= quorumBase / 2 + 1 {
            quorumBase = roster.count   // a majority is still here: the silent ones are really gone
        }
        if var c = collecting {
            c.subtract(gone)
            collecting = c
            if c.isEmpty { finishCollecting(now: now) }
        }
        broadcastRoster()
        advanceCommit()
        closeVoteIfDone(now: now)
    }

    private mutating func broadcastRoster() {
        guard isHost else { return }
        let members = roster.map { RosterMember(peer: $0, status: statuses[$0] ?? status) }
        send(.roster(RosterUpdate(term: term, members: members)), to: clients)
        step.updates.append(.rosterChanged(roster))
        sendProfileToNewMembers()
    }

    private mutating func hostTick(now: Double) {
        let dead = roster.filter { $0 != id && !detector.isAlive($0, now: now) }
        if !dead.isEmpty { dropMembers(dead, now: now) }
        if collecting != nil, now >= collectDeadline,
           collectReports >= collectNeed || now >= collectDeadline + config.collectHardTimeout {
            finishCollecting(now: now)
        }
        if let d = voteDeadline, now >= d { closeVote(now: now) }
        for (shot, d) in clipOfferDeadline where now >= d { decideClip(shot) }
    }

    private mutating func closeVoteIfDone(now: Double) {
        guard isHost, voteDeadline != nil else { return }
        if Set(roster).isSubset(of: ballots.keys) { closeVote(now: now) }
    }

    private mutating func closeVote(now: Double) {
        voteDeadline = nil
        let winner = Vote.winner(roster.compactMap { ballots[$0] })
        send(.ruleVoteResult(RuleVoteResult(voteID: voteID, winner: winner)), to: clients)
        step.updates.append(.ruleVoteClosed(winner))
        _ = append(.ruleSetChosen(winner), now: now, flushing: false)
    }

    private mutating func registerOffer(_ shot: UUID, from: PeerID, score: Double, now: Double) {
        guard clipReceivers[shot] == nil else { return }
        clipOffers[shot, default: [:]][from] = score
        if clipOfferDeadline[shot] == nil { clipOfferDeadline[shot] = now + config.clipOfferWindow }
        if Set(roster).isSubset(of: clipOffers[shot]!.keys) { decideClip(shot) }
    }

    /// Best view wins; the host's own view wins ties (no transfer), then the lowest PeerID.
    private mutating func decideClip(_ shot: UUID) {
        clipOfferDeadline[shot] = nil
        guard let offers = clipOffers.removeValue(forKey: shot), let best = offers.values.max() else { return }
        let top = offers.filter { $0.value == best }.map(\.key)
        let winner = top.contains(id) ? id : top.min()!
        if winner == id {
            if let d = localClips[shot] { step.updates.append(.clipReceived(shotID: shot, from: id, data: d)) }
            releaseClip(shot)
        } else {
            releaseClip(shot)
            clipReceivers[shot] = (winner, ClipReceiver(shotID: shot))
            send(.clipRequest(ClipRequest(shotID: shot)), to: [winner])
        }
    }

    // MARK: - Islands (plan 013a, §2.5)

    struct Island: Sendable {
        var commitSeq: UInt64
        var entries: [LogEntry]
        var settles: [IslandSettle]
    }

    /// Stroke time on the game clock (ns): a client through its host fit + the host's game offset; otherwise through
    /// the frozen fit to the last host, or this phone's own clock if it hosted first. nil = a client without a fit.
    private func gameNs(fromLocal t: Int64) -> Int64? {
        if case .client = role {
            guard let offset = hostGameOffset else { return nil }   // the host has no game clock (Codex re-review R5)
            return clock.hostTime(fromLocal: t).map { $0 + offset }
        }
        guard let g = gameFit else { return everClient ? nil : t }   // never a fabricated game time (Codex P2-8)
        return g.clock.hostTime(fromLocal: t).map { $0 + g.offset }
    }

    private func keptSettles() -> [IslandSettle] {
        kept.map { k in
            let t = gameNs(fromLocal: k.stroke)
            return IslandSettle(event: Self.stamped(k.event, t), strokeHostTime: t)
        }
    }

    static func stamped(_ e: GameEvent, _ t: Int64?) -> GameEvent {
        switch e {
        case .shot(var r):
            r.strokeHostTime = t
            return .shot(r)
        case .shotLost(let id, let team, _):
            return .shotLost(shotID: id, shooterTeam: team, strokeHostTime: t)
        default:
            return e
        }
    }

    private mutating func onIslandLog(_ l: IslandLog, from: PeerID, now: Double) {
        guard isHost else { ignoredMessages += 1; return }
        var got = islandIn[from] ?? (l.commitSeq, [])
        got.entries += l.entries
        guard l.last else { islandIn[from] = got; return }
        islandIn[from] = nil
        pendingIslands[from] = Island(commitSeq: got.commitSeq, entries: got.entries, settles: l.settles)
    }

    /// Merge one phone's log and settles into mine (INTERFACES "Host loss and islands", Heal). Committed entries
    /// never change: mine up to my commit point, and the sender's up to its commit point (pulled in if I lack them).
    /// The rest is merged and written after the longest unchanged prefix; a rewrite bumps the epoch so acks for
    /// replaced entries never count, and nothing it adds is committed before a majority holds it.
    private mutating func heal(_ island: Island) {
        guard isHost, !(island.entries.isEmpty && island.settles.isEmpty) else { return }
        let theirs = island.entries.sorted { $0.seq < $1.seq }
        var p = 0
        while p < min(log.count, theirs.count), log[p].event == theirs[p].event { p += 1 }
        let theirCommit = min(Int(island.commitSeq), theirs.count)
        let myCommit = min(Int(commitSeq), log.count)
        let insert = theirCommit > p && myCommit <= p   // they committed entries I lack; mine after p never were
        let from = insert ? p : max(p, myCommit)
        let fixed = insert ? theirs[p..<theirCommit].map(\.event) : log[p..<from].map(\.event)
        let mine = log[from...].map(\.event)
        let tail = theirs[(insert ? theirCommit : p)...].map(\.event)
        let committed = log[..<p].map(\.event) + fixed
        let settles = island.settles.map(\.event).filter { e in !committed.contains { IslandHeal.matches(e, $0) } }
        guard insert || !tail.isEmpty || !settles.isEmpty else { return }
        let history = Set(log[..<p].compactMap { IslandHeal.id($0.event) })
        let flagged = Set(log.compactMap { if case .shot(let r) = $0.event, r.needsTap { r.shotID } else { nil } })
        let next = (insert ? fixed : []) + IslandHeal.merge(fixed: fixed, mine: mine, others: [tail + settles],
                                                            history: history, flagged: flagged)
        let current = log[from...].map(\.event)
        var same = 0
        while same < min(current.count, next.count), current[same] == next[same] { same += 1 }
        guard same < max(current.count, next.count) else { return }
        let cut = from + same
        if cut < log.count {
            // Above every epoch in the log, inherited ones included, so no ack for a replaced entry ever matches.
            logEpoch = max(logEpoch, log.compactMap(\.epoch).max() ?? 0) + 1
            logVersion += 1
            log.removeSubrange(cut...)
            for (peer, a) in acks { acks[peer] = min(a, UInt64(cut)) }
        }
        for e in next[same...] {
            log.append(LogEntry(seq: lastSeq + 1, term: term, event: e, epoch: logEpoch == 0 ? nil : logEpoch))
        }
        for peer in clients { sendLog(from: UInt64(cut) + 1, to: peer) }
        advanceCommit()
    }

    // MARK: - Client

    private mutating func clientTick(now: Double) {
        guard let h = hostID else { return }
        if now >= nextPing {
            send(.timePing(TimePing(t0: Self.ns(now))), to: [h])
            if pingsLeftInBurst > 0 {
                pingsLeftInBurst -= 1
                nextPing = now + config.pingBurstSpacing
            } else {
                nextPing = now + config.pingInterval
            }
        }
        if var s = clipSender {
            if !ClipSender.mayTransmit(phase) || s.inFlight == 0 {
                clipProgressAt = now
            } else if now - clipProgressAt >= config.clipAckTimeout {
                // A chunk or its ack was lost (failed send, dropped link): resend what is unacknowledged.
                s.resendUnacked()
                clipSender = s
                clipProgressAt = now
            }
        }
        pumpClip()
    }

    private mutating func pumpClip() {
        guard let h = hostID, !isHost, var s = clipSender else { return }
        for c in s.nextChunks(phase: phase) { send(.clipChunk(c), to: [h]) }
        if s.isAcknowledged {
            send(.clipComplete(s.completion), to: [h])
            clipSender = nil
            releaseClip(s.shotID)
        } else {
            clipSender = s
        }
    }

    // MARK: - Plumbing

    private mutating func send(_ m: MeshMessage, to: [PeerID]) {
        let targets = to.filter { $0 != id }
        guard !targets.isEmpty else { return }
        step.outbound.append(Outbound(to: targets, message: m))
    }

    private var lastReported: (UInt64, UInt64, Int) = (0, 0, 0)

    private mutating func flush() -> MeshStep {
        if everJoined { gameMembers.formUnion(roster.filter { !departed.contains($0) }) }
        if isIsland != reportedIsland {
            reportedIsland = isIsland
            step.updates.append(.island(reportedIsland))
        }
        if (lastSeq, commitSeq, logVersion) != lastReported {
            // Plan 013a: a kept settle goes once a committed entry answers its stroke (that one only).
            if !isHost, !kept.isEmpty {
                let committed = committedEntries
                let answered = kept.map { k in
                    let e = Self.stamped(k.event, gameNs(fromLocal: k.stroke))
                    return committed.contains { IslandHeal.matches(e, $0.event) }
                }
                kept = zip(kept, answered).filter { !$0.1 }.map(\.0)
            }
            lastReported = (lastSeq, commitSeq, logVersion)
            step.updates.append(.logChanged(lastSeq: lastSeq, commitSeq: commitSeq))
        }
        defer { step = MeshStep() }
        return step
    }

    static func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }
}

/// Plan 013a: the heal merge over log events (pure). Timed shots go through `IslandMerge`; timed gaps reconcile by
/// stroke time; everything else (untimed shots, taps, corrections, rule set, amendments) follows the timed result
/// before it on its own island.
enum IslandHeal {
    static func id(_ e: GameEvent) -> UUID? {
        switch e {
        case .shot(let r): r.shotID
        case .shotLost(let id, _, _): id
        default: nil
        }
    }

    static func time(_ e: GameEvent) -> Int64? {
        switch e {
        case .shot(let r): r.strokeHostTime
        case .shotLost(_, _, let t): t
        default: nil
        }
    }

    /// The `IslandShot` view of a timed shot record; a D31 guess is less confident.
    static func view(_ e: GameEvent) -> IslandShot? {
        guard case .shot(let r) = e, let t = r.strokeHostTime else { return nil }
        return IslandShot(id: r.shotID, strokeTime: Double(t) / 1e9,
                          preState: r.preState?.balls.mapValues(\.position) ?? [:], outcome: r.outcome,
                          confidence: r.isGuess ? 0.5 : 1)
    }

    /// Two results for the same stroke: the same id; two shots aligned (`IslandMerge.aligned`); or a gap and any
    /// result within the time tolerance.
    static func matches(_ a: GameEvent, _ b: GameEvent) -> Bool {
        if let x = id(a), x == id(b) { return true }
        if let va = view(a), let vb = view(b) { return IslandMerge.aligned(va, vb) }
        guard let ta = time(a), let tb = time(b) else { return false }
        return abs(Double(ta - tb)) / 1e9 <= IslandMerge.timeTolerance
    }

    /// The events to write after `fixed` (committed, never re-emitted) in place of `mine` (my uncommitted tail),
    /// merged with `others` (the sender's uncommitted tail and settles). `history` = shot ids logged before both;
    /// `flagged` = shot ids already carrying `needsTap`.
    /// - Agreeing views: the logged record stays. Disagreeing: the merge's pick with `needsTap`; against a committed
    ///   shot, an amendment (the committed record again, `needsTap`) the fold reads as a flag, not a shot.
    /// - A gap answered by a view of the same stroke goes; a committed gap stands (views of its stroke go); two
    ///   gaps of one stroke are one.
    static func merge(fixed: [GameEvent], mine: [GameEvent], others: [[GameEvent]], history: Set<UUID>,
                      flagged: Set<UUID>) -> [GameEvent] {
        let tol = IslandMerge.timeTolerance
        // The committed part is its own island: after a minority won the term it is the majority's view, not mine.
        let islands = [fixed, mine] + others
        let fixedShotIDs = Set(fixed.compactMap(id))
        // A shot whose id appeared before (history, the committed part, or earlier on its island) is an amendment.
        var amendment: Set<String> = []
        for (k, l) in islands.enumerated() {
            var seen = k == 1 ? history.union(fixedShotIDs) : history
            for (j, e) in l.enumerated() {
                guard case .shot(let r) = e else { continue }
                if !seen.insert(r.shotID).inserted { amendment.insert("\(k):\(j)") }
            }
        }
        func shotView(_ k: Int, _ j: Int) -> IslandShot? { amendment.contains("\(k):\(j)") ? nil : view(islands[k][j]) }
        var records: [UUID: MeshShotRecord] = [:]
        for l in islands.reversed() { for case .shot(let r) in l.reversed() { records[r.shotID] = r } }   // committed, then mine, win
        let views = islands.enumerated().map { k, l in l.indices.compactMap { shotView(k, $0) } }
        let clusters = IslandMerge.merge(views)
        var clusterOf: [UUID: Int] = [:]
        for (i, c) in clusters.enumerated() { for m in c.members { clusterOf[m] = i } }
        let time = Dictionary(views.joined().map { ($0.id, $0.strokeTime) }, uniquingKeysWith: min)
        let starts = clusters.map { c in c.members.compactMap { time[$0] }.min() ?? 0 }
        let fixedIDs = Set(fixed.compactMap { view($0)?.id })
        let logged = Set((fixed + mine).compactMap { if case .shot(let r) = $0 { r.shotID } else { nil } })

        // Timed gaps, committed first, then mine, then the others'.
        struct Gap { var k: Int; var j: Int; var time: Double; var fixed: Bool }
        var gaps: [Gap] = []
        for (k, l) in islands.enumerated() {
            for (j, e) in l.enumerated() {
                if case .shotLost = e, let t = Self.time(e) { gaps.append(Gap(k: k, j: j, time: Double(t) / 1e9, fixed: k == 0)) }
            }
        }
        gaps.sort { ($0.fixed ? 0 : 1, $0.k, $0.time) < ($1.fixed ? 0 : 1, $1.k, $1.time) }
        var items: [(time: Double, emit: GameEvent?)] = clusters.indices.map { (starts[$0], nil) }
        var itemOf: [String: Int] = [:]
        var placed: [(time: Double, item: Int)] = []
        for g in gaps {
            let key = "\(g.k):\(g.j)"
            if g.fixed {
                items.append((g.time, nil))
                itemOf[key] = items.count - 1
                placed.append((g.time, items.count - 1))
            } else if let c = clusters.indices.first(where: { abs(starts[$0] - g.time) <= tol }) {
                itemOf[key] = c                                  // a view answers this stroke
            } else if let rep = placed.first(where: { abs($0.time - g.time) <= tol }) {
                itemOf[key] = rep.item                           // another gap of the same stroke
            } else {
                items.append((g.time, islands[g.k][g.j]))
                itemOf[key] = items.count - 1
                placed.append((g.time, items.count - 1))
            }
        }
        let fixedGapTimes = gaps.filter(\.fixed).map(\.time)
        for (i, c) in clusters.enumerated() {
            if c.members.contains(where: fixedIDs.contains) {
                let f = c.members.first(where: fixedIDs.contains)!
                let disagree = c.needsTap || c.members.contains { $0 != f && records[$0]?.needsTap == true }
                if disagree, !flagged.contains(f), var r = records[f], !r.needsTap {
                    r.needsTap = true
                    items[i].emit = .shot(r)                     // amendment: flag the committed shot
                }
            } else if !fixedGapTimes.contains(where: { abs($0 - starts[i]) <= tol }) {
                let pick = c.needsTap ? c.shot.id : (c.members.first(where: logged.contains) ?? c.shot.id)
                if var r = records[pick] {
                    r.needsTap = c.needsTap || c.members.contains { records[$0]?.needsTap == true }
                    items[i].emit = .shot(r)
                }
            }
        }

        // Everything else follows the timed result before it on its own island.
        var knownShots = logged.union(clusterOf.keys).union(history)
        var knownEvents = Set(fixed + mine)
        var flags = flagged.union((fixed + mine).compactMap { if case .shot(let r) = $0, r.needsTap { r.shotID } else { nil } })
        var after: [Int: [GameEvent]] = [:]
        for (k, l) in islands.enumerated() {
            var anchor = -1
            for (j, e) in l.enumerated() {
                if let v = shotView(k, j) { anchor = clusterOf[v.id] ?? anchor; continue }
                if let it = itemOf["\(k):\(j)"] { anchor = it; continue }
                if k == 0 { continue }
                if k > 1 {
                    if case .shot(let r) = e {
                        // A known shot again: dropped, unless it carries a flag the log lacks (an amendment travels).
                        let fresh = knownShots.insert(r.shotID).inserted
                        guard fresh || (r.needsTap && flags.insert(r.shotID).inserted) else { continue }
                    } else {
                        guard knownEvents.insert(e).inserted else { continue }
                    }
                }
                after[anchor, default: []].append(e)
            }
        }
        var out = after[-1] ?? []
        for i in items.indices.sorted(by: { (items[$0].time, $0) < (items[$1].time, $1) }) {
            if let e = items[i].emit { out.append(e) }
            out += after[i] ?? []
        }
        return out
    }
}
