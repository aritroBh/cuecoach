import Foundation

/// Ranking order for host election. The spec says "newest device / highest battery" without saying
/// which wins (mesh-identity.md Q7, open). Default = spec-literal device first; switchable.
enum ElectionOrder: String, Sendable, Codable, CaseIterable {
    case deviceFirst, batteryFirst
    static let `default`: ElectionOrder = .deviceFirst
}

/// Deterministic election: every phone ranks the same gossiped `PeerStatus` set and gets the same answer.
/// No vote round. Hysteresis (a sitting host stays while alive) is applied by `MeshNode`, not here.
enum HostElection {
    /// 10 % buckets so a few percent of drain doesn't reshuffle the succession list.
    static func batteryBucket(_ percent: Int) -> Int { max(0, min(100, percent)) / 10 }

    /// Best first. Ties fall through to `onPower`, then the lowest `PeerID`.
    static func succession(_ statuses: [PeerID: PeerStatus], order: ElectionOrder) -> [PeerID] {
        statuses.sorted { better($0.key, $0.value, than: $1.key, $1.value, order: order) }.map(\.key)
    }

    static func elect(_ statuses: [PeerID: PeerStatus], order: ElectionOrder) -> PeerID? {
        succession(statuses, order: order).first
    }

    /// Raft-style terms: higher term wins; an equal-term conflict (two claimants after a split view)
    /// goes to the better-ranked claimant, so every phone resolves it the same way.
    static func claimWins(term: UInt64, claimant: PeerID, over currentTerm: UInt64, incumbent: PeerID?,
                          statuses: [PeerID: PeerStatus], order: ElectionOrder) -> Bool {
        if term != currentTerm { return term > currentTerm }
        guard let incumbent, incumbent != claimant else { return false }
        guard let cs = statuses[claimant] else { return false }
        guard let inc = statuses[incumbent] else { return true }
        return better(claimant, cs, than: incumbent, inc, order: order)
    }

    static func better(_ a: PeerID, _ sa: PeerStatus, than b: PeerID, _ sb: PeerStatus,
                       order: ElectionOrder) -> Bool {
        let ba = batteryBucket(sa.batteryPercent), bb = batteryBucket(sb.batteryPercent)
        let (a1, a2, b1, b2) = order == .deviceFirst
            ? (sa.deviceClass, ba, sb.deviceClass, bb)
            : (ba, sa.deviceClass, bb, sb.deviceClass)
        if a1 != b1 { return a1 > b1 }
        if a2 != b2 { return a2 > b2 }
        if sa.onPower != sb.onPower { return sa.onPower }
        return a < b
    }
}

/// Static model rank from `utsname.machine` ("iPhone16,2" → 16). Unknown models and simulators rank 0.
/// Upkeep: none needed for new iPhones — the identifier's major number grows with each generation.
enum DeviceClass {
    static func rank(machine: String) -> Int {
        guard machine.hasPrefix("iPhone"),
              let major = machine.dropFirst("iPhone".count).split(separator: ",").first,
              let n = Int(major) else { return 0 }
        return n
    }

    static var current: Int {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return rank(machine: machine)
    }
}

/// Marks a peer dead after `timeout` seconds without hearing anything from it.
/// `timeout` is an assumption (1.5 s) to be tuned from measured AWDL heartbeat gaps (mesh-identity.md §2.5).
struct FailureDetector: Sendable {
    var timeout: Double
    private(set) var lastHeard: [PeerID: Double] = [:]

    init(timeout: Double = 1.5) { self.timeout = timeout }

    mutating func heard(_ p: PeerID, at t: Double) { lastHeard[p] = max(lastHeard[p] ?? t, t) }
    mutating func forget(_ p: PeerID) { lastHeard[p] = nil }

    func isAlive(_ p: PeerID, now: Double) -> Bool {
        guard let t = lastHeard[p] else { return false }
        return now - t <= timeout
    }

    /// Half the timeout: only dims the peer glyph, triggers nothing.
    func isSuspect(_ p: PeerID, now: Double) -> Bool {
        guard let t = lastHeard[p] else { return true }
        return now - t >= timeout / 2
    }

    func alive(now: Double) -> Set<PeerID> { Set(lastHeard.keys.filter { isAlive($0, now: now) }) }
}
