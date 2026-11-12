import Foundation

/// Per-session random peer identity (TN3213: own random UUID, never a device identifier).
struct PeerID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }

    init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(UUID.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    static func < (l: PeerID, r: PeerID) -> Bool { l.raw.uuidString < r.raw.uuidString }
    var description: String { String(raw.uuidString.prefix(4)) }
}

/// Delivery class. MPC maps `.reliable` → `MCSessionSendDataMode.reliable` (ordered, retransmitted) and
/// `.unreliable` → `.unreliable` (best effort, may drop or reorder). Bulk clip transfer rides `.reliable`
/// with an app-level window because MPC has no back-pressure (mesh-identity.md §2.2).
enum MeshChannel: String, Codable, Sendable, CaseIterable {
    case reliable, unreliable
}

/// Wire protocol version (mesh-identity.md §3.3). `major` breaks decoding/meaning; `minor` is additive only.
struct ProtocolVersion: Hashable, Codable, Sendable {
    var major: Int
    var minor: Int

    /// Major 2 (plan 009): `GameEvent` gained `.nextShooter` and `.shotLost`, which a major-1 build can't decode.
    static let current = ProtocolVersion(major: 2, minor: 0)
    static let supportedMajors: [Int] = [2]

    /// Highest major both sides speak, or `nil` (→ `Reject`).
    static func negotiate(local: [Int], remote: [Int]) -> Int? {
        Set(local).intersection(remote).max()
    }
}

/// Game phase as the host sees it. Clip chunks flow only outside `.aiming` (D3).
enum MeshPhase: String, Codable, Sendable {
    case lobby, aiming, inMotion, settled, gameOver
}
