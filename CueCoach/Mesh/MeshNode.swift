import Foundation
import Rules

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
    let sessionID = UUID()

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

    // host
    private var acks: [PeerID: UInt64] = [:]
    private var collecting: Set<PeerID>?
    private var collectDeadline = 0.0
    private var pendingHellos: [PeerID] = []
    private var pendingAppends: [GameEvent] = []
    private var voteID: UInt64 = 0
    private var ballots: [PeerID: RuleSetID] = [:]
    private var voteDeadline: Double?
    private var clipOffers: [UUID: [PeerID: Double]] = [:]
    private var clipOfferDeadline: [UUID: Double] = [:]
    private var clipReceivers: [UUID: (from: PeerID, receiver: ClipReceiver)] = [:]

    private var step = MeshStep()

    init(id: PeerID = PeerID(), status: PeerStatus, config: MeshConfig = MeshConfig()) {
        self.id = id
        self.status = status
        self.config = config
        detector = FailureDetector(timeout: config.failTimeout)
        statuses[id] = status
    }

    var lastSeq: UInt64 { log.last?.seq ?? 0 }
    var isHost: Bool { role == .host }

    // MARK: - Inputs

    mutating func start(now: Double) -> MeshStep {
        startedAt = now
        return flush()
    }

    mutating func peerConnected(_ p: PeerID, now: Double) -> MeshStep {
        guard rejected == nil else { return flush() }
        connected.insert(p)
        detector.heard(p, at: now)
        send(.peerStatus(status), to: [p])
        if isHost { send(heartbeat, to: [p]) }
        return flush()
    }

    mutating func peerDisconnected(_ p: PeerID, now: Double) -> MeshStep {
        connected.remove(p)
        detector.forget(p)
        guard rejected == nil else { return flush() }
        if isHost {
            dropMembers([p], now: now)
        } else if p == hostID {
            hostLost(now: now)
        }
        return flush()
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
        guard rejected == nil, env.sender != id else { return flush() }
        let from = env.sender
        detector.heard(from, at: now)
        switch env.message {
        case .hello(let h): onHello(h, from: from, now: now)
        case .welcome(let w): onWelcome(w, from: from, now: now)
        case .reject(let r): onReject(r, from: from)
        case .leave: _ = peerDisconnected(from, now: now)
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
            if isHost, a.term == term, roster.contains(from) {
                acks[from] = max(acks[from] ?? 0, min(a.upTo, lastSeq))
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
            if from == hostID, let d = localClips[r.shotID] {
                clipSender = ClipSender(shotID: r.shotID, data: d)
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
                pumpClip()
            }
        case .clipComplete(let c):
            if isHost, let entry = clipReceivers[c.shotID], entry.from == from {
                if entry.receiver.finish(c), let d = entry.receiver.assembled {
                    clipReceivers[c.shotID] = nil
                    step.updates.append(.clipReceived(shotID: c.shotID, from: from, data: d))
                } else {
                    // Whole-clip hash failed: ask again from scratch.
                    clipReceivers[c.shotID] = (from, ClipReceiver(shotID: c.shotID))
                    send(.clipRequest(ClipRequest(shotID: c.shotID)), to: [from])
                }
            }
        case .unknown: break
        }
        return flush()
    }

    mutating func tick(now: Double) -> MeshStep {
        guard rejected == nil else { return flush() }
        if now - lastLiveness >= config.heartbeatInterval {
            lastLiveness = now
            if isHost { send(heartbeat, to: Array(connected)) }
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
        localClips[shotID] = data
        if isHost {
            registerOffer(shotID, from: id, score: viewScore, now: now)
        } else if let h = hostID {
            send(.clipOffer(ClipOffer(shotID: shotID, viewScore: viewScore, byteSize: data.count)), to: [h])
        }
        return flush()
    }

    mutating func leave(now: Double) -> MeshStep {
        send(.leave, to: Array(connected))
        return flush()
    }

    // MARK: - Election + migration

    private var heartbeat: MeshMessage {
        .heartbeat(Heartbeat(term: term, host: id, lastSeq: lastSeq, commitSeq: commitSeq, phase: phase))
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
        roster = [id] + c.keys.filter { $0 != id && everJoined }.sorted()
        everJoined = true
        let survivors = Set(roster).subtracting([id])
        collecting = survivors.isEmpty ? nil : survivors
        collectDeadline = now + config.collectTimeout
        send(.hostClaim(HostClaim(term: term, lastSeq: lastSeq)), to: Array(connected))
        send(heartbeat, to: Array(connected))
        step.updates.append(.roleChanged(.host, term: term))
        broadcastRoster()
        if collecting == nil { finishCollecting(now: now) }
    }

    /// Accepting `host` at `newTerm` (from a heartbeat, claim or welcome).
    private mutating func adopt(host h: PeerID, term newTerm: UInt64, now: Double) {
        let wasHost = isHost
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
        if wasHost { pendingAppends.forEach { send(.proposal($0), to: [h]) }; pendingAppends = [] }
        clock.reset()
        pingsLeftInBurst = config.pingBurst
        nextPing = now
        // Give the new host anything it may lack (ordered before the hello on the reliable channel),
        // then ask to be welcomed; the welcome carries the authoritative log.
        send(.logEntries(log.filter { $0.seq > commitSeq }), to: [h])
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
            if synced {
                commitSeq = max(commitSeq, min(hb.commitSeq, lastSeq))
                if hb.lastSeq > lastSeq { requestTail(now: now) }
            }
            if hb.phase != phase { phase = hb.phase; step.updates.append(.phase(hb.phase)) }
            return
        }
        if wins(term: hb.term, claimant: from) {
            adopt(host: from, term: hb.term, now: now)
        } else if isHost {
            send(heartbeat, to: [from])          // the stale side will step down
        }
    }

    private mutating func onHostClaim(_ c: HostClaim, from: PeerID, now: Double) {
        if wins(term: c.term, claimant: from) {
            adopt(host: from, term: c.term, now: now)
        } else if isHost {
            send(heartbeat, to: [from])
        }
    }

    private mutating func onWelcome(_ w: Welcome, from: PeerID, now: Double) {
        guard w.host == from else { return }
        if from != hostID || w.term != term {
            guard wins(term: w.term, claimant: from) else { return }
            adopt(host: from, term: w.term, now: now)
        }
        log = w.log
        synced = true
        commitSeq = min(w.commitSeq, lastSeq)
        roster = w.roster
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
        }
        statuses[from] = PeerStatus(deviceClass: h.deviceClass, batteryPercent: h.batteryPercent, onPower: h.onPower)
        if var c = collecting {
            c.remove(from)
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
                let entry = LogEntry(seq: lastSeq + 1, term: term, event: e)
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
            // A survivor's (or a stepped-down host's) tail: adopt only what extends my log contiguously.
            var added: [LogEntry] = []
            for e in sorted where e.seq == lastSeq + 1 {
                log.append(e)
                added.append(e)
            }
            if !added.isEmpty, collecting == nil { send(.logEntries(added), to: clients) }
            advanceCommit()
            return
        }
        guard from == hostID, synced, let first = sorted.first else { return }
        if first.seq > lastSeq + 1 { requestTail(now: now); return }
        log = log.filter { $0.seq < first.seq } + sorted
        sendAck()
    }

    private mutating func sendAck() {
        guard let h = hostID, !isHost else { return }
        send(.logAck(LogAck(term: term, upTo: lastSeq)), to: [h])
    }

    private mutating func requestTail(now: Double) {
        guard let h = hostID, now - lastTailRequest >= 0.5 else { return }
        lastTailRequest = now
        send(.logTailRequest(LogTailRequest(fromSeq: lastSeq + 1)), to: [h])
    }

    private mutating func advanceCommit() {
        guard isHost, !roster.isEmpty else { return }
        let acked = roster.map { $0 == id ? lastSeq : (acks[$0] ?? 0) }.sorted(by: >)
        commitSeq = max(commitSeq, acked[roster.count / 2])
    }

    private mutating func dropMembers(_ gone: [PeerID], now: Double) {
        let before = roster
        let me = id
        roster.removeAll { gone.contains($0) && $0 != me }
        for p in gone { acks[p] = nil; ballots[p] = nil }
        guard roster != before else { return }
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
    }

    private mutating func hostTick(now: Double) {
        let dead = roster.filter { $0 != id && !detector.isAlive($0, now: now) }
        if !dead.isEmpty { dropMembers(dead, now: now) }
        if collecting != nil, now >= collectDeadline { finishCollecting(now: now) }
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
        } else {
            clipReceivers[shot] = (winner, ClipReceiver(shotID: shot))
            send(.clipRequest(ClipRequest(shotID: shot)), to: [winner])
        }
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
        pumpClip()
    }

    private mutating func pumpClip() {
        guard let h = hostID, !isHost, var s = clipSender else { return }
        for c in s.nextChunks(phase: phase) { send(.clipChunk(c), to: [h]) }
        if s.isAcknowledged {
            send(.clipComplete(s.completion), to: [h])
            clipSender = nil
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

    private var lastReported: (UInt64, UInt64) = (0, 0)

    private mutating func flush() -> MeshStep {
        if (lastSeq, commitSeq) != lastReported {
            lastReported = (lastSeq, commitSeq)
            step.updates.append(.logChanged(lastSeq: lastSeq, commitSeq: commitSeq))
        }
        defer { step = MeshStep() }
        return step
    }

    static func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }
}
