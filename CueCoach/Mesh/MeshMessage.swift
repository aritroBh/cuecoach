import Foundation
import Geometry
import Rules

// MARK: - Payloads (mesh-identity.md §3.2). All value types; JSON on the wire.

struct Hello: Hashable, Codable, Sendable {
    var deviceClass: Int
    var batteryPercent: Int
    var onPower: Bool
    var supportedMajors: [Int]
}

struct Welcome: Hashable, Codable, Sendable {
    var term: UInt64
    var host: PeerID
    var roster: [PeerID]
    var log: [LogEntry]
    var commitSeq: UInt64
}

enum RejectReason: String, Hashable, Codable, Sendable {
    case versionTooOld, versionTooNew, sessionFull, wrongSession
}

struct Heartbeat: Hashable, Codable, Sendable {
    var term: UInt64
    var host: PeerID
    var lastSeq: UInt64
    var commitSeq: UInt64
    var phase: MeshPhase
}

/// Election inputs, gossiped by every phone (mesh-identity.md §2.4).
struct PeerStatus: Hashable, Codable, Sendable {
    /// Static rank of the model (higher = newer/faster). Unknown models → 0.
    var deviceClass: Int
    var batteryPercent: Int
    var onPower: Bool
}

struct RosterMember: Hashable, Codable, Sendable {
    var peer: PeerID
    var status: PeerStatus
}

/// Host → all: admitted members (≤ 8) and their election inputs. Clients elect only from this list.
struct RosterUpdate: Hashable, Codable, Sendable {
    var term: UInt64
    var members: [RosterMember]
}

struct HostClaim: Hashable, Codable, Sendable {
    var term: UInt64
    var lastSeq: UInt64
}

/// NTP-style ping, host-time nanoseconds (RFC 5905 §8).
struct TimePing: Hashable, Codable, Sendable { var t0: Int64 }
struct TimePong: Hashable, Codable, Sendable { var t0: Int64; var t1: Int64; var t2: Int64 }

struct RuleVoteOpen: Hashable, Codable, Sendable {
    var voteID: UInt64
    /// Seconds the host waits for ballots; missing ballots then count as "no vote".
    var deadline: Double
}
struct RuleBallot: Hashable, Codable, Sendable { var voteID: UInt64; var choice: RuleSetID }
struct RuleVoteResult: Hashable, Codable, Sendable { var voteID: UInt64; var winner: RuleSetID }

/// One tracked ball in table coordinates (metres), from one phone's tracker.
struct BallDetection: Hashable, Codable, Sendable {
    var ball: BallID
    var position: Vec2
    /// 1-σ position uncertainty, metres.
    var sigma: Double
    var confidence: Double
}

/// Timestamped table-coordinate detections (never video, SPEC §5.7). Sent on `.unreliable`.
struct TableStateFrame: Hashable, Codable, Sendable {
    /// Capture time on the sender's host clock, nanoseconds. The host converts with the clock-sync offset.
    var captureTime: Int64
    var balls: [BallDetection]
}

struct ShotRecord: Hashable, Codable, Sendable {
    var shotID: UUID
    var shooterTeam: Int
    var outcome: ShotOutcome
    var postState: TableState?
}

/// Replicated game-log event. `GameState = fold(log)` on any phone (mesh-identity.md §2.5).
enum GameEvent: Hashable, Codable, Sendable {
    case ruleSetChosen(RuleSetID)
    case shot(ShotRecord)
    case shooterCorrection(shotID: UUID, team: Int)
}

struct LogEntry: Hashable, Codable, Sendable {
    var seq: UInt64
    var term: UInt64
    var event: GameEvent
}

struct LogAck: Hashable, Codable, Sendable { var term: UInt64; var upTo: UInt64 }
struct LogTailRequest: Hashable, Codable, Sendable { var fromSeq: UInt64 }

struct CalibrationReport: Hashable, Codable, Sendable {
    /// Row-major 3×3 image→table homography.
    var homography: [Double]
    var residualPixels: Double
    var tableSize: TableSize
}

struct ClipOffer: Hashable, Codable, Sendable { var shotID: UUID; var viewScore: Double; var byteSize: Int }
struct ClipRequest: Hashable, Codable, Sendable { var shotID: UUID }
struct ClipChunk: Hashable, Codable, Sendable {
    var shotID: UUID
    var index: Int
    var total: Int
    var totalBytes: Int
    var bytes: Data
    /// SHA-256 of `bytes`.
    var sha256: Data
}
struct ClipChunkAck: Hashable, Codable, Sendable { var shotID: UUID; var index: Int; var ok: Bool }
struct ClipComplete: Hashable, Codable, Sendable {
    var shotID: UUID
    /// SHA-256 of the whole clip.
    var sha256: Data
}

// MARK: - Message

enum MeshMessage: Hashable, Sendable {
    case hello(Hello)
    case welcome(Welcome)
    case reject(RejectReason)
    case leave
    case heartbeat(Heartbeat)
    case peerStatus(PeerStatus)
    case roster(RosterUpdate)
    case hostClaim(HostClaim)
    case timePing(TimePing)
    case timePong(TimePong)
    case ruleVoteOpen(RuleVoteOpen)
    case ruleBallot(RuleBallot)
    case ruleVoteResult(RuleVoteResult)
    case tableState(TableStateFrame)
    /// Client → host: please append this event (host is the only writer).
    case proposal(GameEvent)
    /// Host → clients: log entries (new appends, catch-up, or post-migration authoritative tail).
    /// Clients → new host: their tail after a `HostClaim`.
    case logEntries([LogEntry])
    case logAck(LogAck)
    case logTailRequest(LogTailRequest)
    case calibration(CalibrationReport)
    case phaseChange(MeshPhase)
    case clipOffer(ClipOffer)
    case clipRequest(ClipRequest)
    case clipChunk(ClipChunk)
    case clipChunkAck(ClipChunkAck)
    case clipComplete(ClipComplete)
    /// A type from a newer minor version. Ignored (and counted in the debug HUD).
    case unknown(type: String)

    enum Kind: String, CaseIterable, Sendable {
        case hello, welcome, reject, leave, heartbeat, peerStatus, roster, hostClaim, timePing, timePong
        case ruleVoteOpen, ruleBallot, ruleVoteResult, tableState, proposal, logEntries, logAck, logTailRequest
        case calibration, phaseChange, clipOffer, clipRequest, clipChunk, clipChunkAck, clipComplete, unknown
    }

    var kind: Kind {
        switch self {
        case .hello: .hello
        case .welcome: .welcome
        case .reject: .reject
        case .leave: .leave
        case .heartbeat: .heartbeat
        case .peerStatus: .peerStatus
        case .roster: .roster
        case .hostClaim: .hostClaim
        case .timePing: .timePing
        case .timePong: .timePong
        case .ruleVoteOpen: .ruleVoteOpen
        case .ruleBallot: .ruleBallot
        case .ruleVoteResult: .ruleVoteResult
        case .tableState: .tableState
        case .proposal: .proposal
        case .logEntries: .logEntries
        case .logAck: .logAck
        case .logTailRequest: .logTailRequest
        case .calibration: .calibration
        case .phaseChange: .phaseChange
        case .clipOffer: .clipOffer
        case .clipRequest: .clipRequest
        case .clipChunk: .clipChunk
        case .clipChunkAck: .clipChunkAck
        case .clipComplete: .clipComplete
        case .unknown: .unknown
        }
    }

    /// Default channel. Only detections and time pings tolerate loss.
    var defaultChannel: MeshChannel {
        switch self {
        case .tableState, .timePing, .timePong: .unreliable
        default: .reliable
        }
    }
}

extension MeshMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, body }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: type), kind != .unknown else {
            self = .unknown(type: type)
            return
        }
        func body<T: Decodable>(_: T.Type) throws -> T { try c.decode(T.self, forKey: .body) }
        switch kind {
        case .hello: self = .hello(try body(Hello.self))
        case .welcome: self = .welcome(try body(Welcome.self))
        case .reject: self = .reject(try body(RejectReason.self))
        case .leave: self = .leave
        case .heartbeat: self = .heartbeat(try body(Heartbeat.self))
        case .peerStatus: self = .peerStatus(try body(PeerStatus.self))
        case .roster: self = .roster(try body(RosterUpdate.self))
        case .hostClaim: self = .hostClaim(try body(HostClaim.self))
        case .timePing: self = .timePing(try body(TimePing.self))
        case .timePong: self = .timePong(try body(TimePong.self))
        case .ruleVoteOpen: self = .ruleVoteOpen(try body(RuleVoteOpen.self))
        case .ruleBallot: self = .ruleBallot(try body(RuleBallot.self))
        case .ruleVoteResult: self = .ruleVoteResult(try body(RuleVoteResult.self))
        case .tableState: self = .tableState(try body(TableStateFrame.self))
        case .proposal: self = .proposal(try body(GameEvent.self))
        case .logEntries: self = .logEntries(try body([LogEntry].self))
        case .logAck: self = .logAck(try body(LogAck.self))
        case .logTailRequest: self = .logTailRequest(try body(LogTailRequest.self))
        case .calibration: self = .calibration(try body(CalibrationReport.self))
        case .phaseChange: self = .phaseChange(try body(MeshPhase.self))
        case .clipOffer: self = .clipOffer(try body(ClipOffer.self))
        case .clipRequest: self = .clipRequest(try body(ClipRequest.self))
        case .clipChunk: self = .clipChunk(try body(ClipChunk.self))
        case .clipChunkAck: self = .clipChunkAck(try body(ClipChunkAck.self))
        case .clipComplete: self = .clipComplete(try body(ClipComplete.self))
        case .unknown: self = .unknown(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if case .unknown(let type) = self {
            try c.encode(type, forKey: .type)
            return
        }
        try c.encode(kind.rawValue, forKey: .type)
        switch self {
        case .hello(let v): try c.encode(v, forKey: .body)
        case .welcome(let v): try c.encode(v, forKey: .body)
        case .reject(let v): try c.encode(v, forKey: .body)
        case .leave, .unknown: break
        case .heartbeat(let v): try c.encode(v, forKey: .body)
        case .peerStatus(let v): try c.encode(v, forKey: .body)
        case .roster(let v): try c.encode(v, forKey: .body)
        case .hostClaim(let v): try c.encode(v, forKey: .body)
        case .timePing(let v): try c.encode(v, forKey: .body)
        case .timePong(let v): try c.encode(v, forKey: .body)
        case .ruleVoteOpen(let v): try c.encode(v, forKey: .body)
        case .ruleBallot(let v): try c.encode(v, forKey: .body)
        case .ruleVoteResult(let v): try c.encode(v, forKey: .body)
        case .tableState(let v): try c.encode(v, forKey: .body)
        case .proposal(let v): try c.encode(v, forKey: .body)
        case .logEntries(let v): try c.encode(v, forKey: .body)
        case .logAck(let v): try c.encode(v, forKey: .body)
        case .logTailRequest(let v): try c.encode(v, forKey: .body)
        case .calibration(let v): try c.encode(v, forKey: .body)
        case .phaseChange(let v): try c.encode(v, forKey: .body)
        case .clipOffer(let v): try c.encode(v, forKey: .body)
        case .clipRequest(let v): try c.encode(v, forKey: .body)
        case .clipChunk(let v): try c.encode(v, forKey: .body)
        case .clipChunkAck(let v): try c.encode(v, forKey: .body)
        case .clipComplete(let v): try c.encode(v, forKey: .body)
        }
    }
}

/// Everything on the wire is one envelope.
struct MeshEnvelope: Hashable, Codable, Sendable {
    var version: ProtocolVersion
    var sessionID: UUID
    var sender: PeerID
    /// Per-sender monotonic counter (debug / duplicate detection).
    var seq: UInt64
    /// Sender host-clock time, nanoseconds.
    var sentAt: Int64
    var message: MeshMessage
}

enum MeshCodecError: Error, Equatable {
    case malformed
    case incompatibleMajor(Int)
    case tooLarge(Int)
}

/// Wire format: `"CUE"` + major byte + JSON envelope. The major byte lets a peer reject a
/// different-major message before parsing it.
enum MeshCodec {
    static let magic: [UInt8] = [0x43, 0x55, 0x45]
    /// Upper bound for one message; a 64 KiB clip chunk base64-encodes to ~88 KiB.
    static let maxMessageBytes = 128 * 1024

    static func encode(_ env: MeshEnvelope) throws -> Data {
        let json = try JSONEncoder().encode(env)
        let data = framed(json, major: env.version.major)
        guard data.count <= maxMessageBytes else { throw MeshCodecError.tooLarge(data.count) }
        return data
    }

    static func framed(_ json: Data, major: Int = ProtocolVersion.current.major) -> Data {
        var d = Data(magic)
        d.append(UInt8(truncatingIfNeeded: major))
        d.append(json)
        return d
    }

    static func decode(_ data: Data) throws -> MeshEnvelope {
        guard data.count > 4, data.count <= maxMessageBytes,
              Array(data.prefix(3)) == magic else { throw MeshCodecError.malformed }
        let major = Int(data[data.startIndex + 3])
        guard ProtocolVersion.supportedMajors.contains(major) else { throw MeshCodecError.incompatibleMajor(major) }
        guard let env = try? JSONDecoder().decode(MeshEnvelope.self, from: data.dropFirst(4)),
              env.version.major == major else { throw MeshCodecError.malformed }
        return env
    }
}
