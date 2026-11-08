import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

/// Versioned wire codec (mesh-identity.md §3).
@Suite struct MeshCodecTests {
    static let a = PeerID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    static let b = PeerID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
    static let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let shot = UUID(uuidString: "99999999-0000-0000-0000-000000000001")!

    static var sampleOutcome: ShotOutcome {
        var o = ShotOutcome()
        o.firstContact = BallID(3)!
        o.pocketed = [BallID(3)!: .footLeft]
        o.anyRailAfterContact = true
        return o
    }

    /// One instance of every message case. Adding a case without adding it here fails `everyCaseIsCovered`.
    static var everyMessage: [MeshMessage] {
        let entry = LogEntry(seq: 1, term: 2, event: .shot(MeshShotRecord(shotID: shot, shooterTeam: 1,
                                                                        outcome: sampleOutcome, postState: nil)))
        return [
            .hello(Hello(deviceClass: 17, batteryPercent: 80, onPower: false, supportedMajors: [1])),
            .welcome(Welcome(term: 3, host: a, roster: [a, b], log: [entry], commitSeq: 1)),
            .reject(.sessionFull),
            .leave,
            .heartbeat(Heartbeat(term: 3, host: a, lastSeq: 1, commitSeq: 1, phase: .settled)),
            .peerStatus(PeerStatus(deviceClass: 15, batteryPercent: 42, onPower: true)),
            .roster(RosterUpdate(term: 3, members: [RosterMember(peer: a, status: PeerStatus(
                deviceClass: 16, batteryPercent: 50, onPower: false))])),
            .hostClaim(HostClaim(term: 4, lastSeq: 7)),
            .timePing(TimePing(t0: 100)),
            .timePong(TimePong(t0: 100, t1: 150, t2: 151)),
            .ruleVoteOpen(RuleVoteOpen(voteID: 1, deadline: 20)),
            .ruleBallot(RuleBallot(voteID: 1, choice: .wpaNine)),
            .ruleVoteResult(RuleVoteResult(voteID: 1, winner: .barEight)),
            .tableState(TableStateFrame(captureTime: 1_000_000, balls: [
                MeshBallDetection(ball: .cue, position: Vec2(0.5, 0.25), sigma: 0.004, confidence: 0.9)])),
            .proposal(.shooterCorrection(shotID: shot, team: 0)),
            .logEntries([entry]),
            .logAck(LogAck(term: 2, upTo: 1)),
            .logTailRequest(LogTailRequest(fromSeq: 1)),
            .calibration(CalibrationReport(homography: [1, 0, 0, 0, 1, 0, 0, 0, 1], residualPixels: 1.5,
                                           tableSize: .sevenFoot)),
            .phaseChange(.aiming),
            .clipOffer(ClipOffer(shotID: shot, viewScore: 0.7, byteSize: 300_000)),
            .clipRequest(ClipRequest(shotID: shot)),
            .clipChunk(ClipChunk(shotID: shot, index: 2, total: 5, totalBytes: 300_000,
                                 bytes: Data([1, 2, 3]), sha256: Data(repeating: 7, count: 32))),
            .clipChunkAck(ClipChunkAck(shotID: shot, index: 2, ok: true)),
            .clipComplete(ClipComplete(shotID: shot, sha256: Data(repeating: 9, count: 32))),
            .profile(ProfileShare(summary: Data([1, 2, 3]))),
        ]
    }

    static func envelope(_ m: MeshMessage, seq: UInt64 = 5) -> MeshEnvelope {
        MeshEnvelope(version: .current, sessionID: session, sender: a, seq: seq, sentAt: 123_456_789, message: m)
    }

    @Test func everyCaseIsCovered() {
        let kinds = Set(Self.everyMessage.map(\.kind))
        #expect(kinds == Set(MeshMessage.Kind.allCases.filter { $0 != .unknown }))
    }

    @Test(arguments: MeshCodecTests.everyMessage)
    func roundTripsEveryMessage(_ m: MeshMessage) throws {
        let env = Self.envelope(m)
        let data = try MeshCodec.encode(env)
        let back = try MeshCodec.decode(data)
        #expect(back == env)
    }

    @Test func wireStartsWithMagicAndMajor() throws {
        let data = try MeshCodec.encode(Self.envelope(.leave))
        #expect(Array(data.prefix(4)) == [0x43, 0x55, 0x45, UInt8(ProtocolVersion.current.major)]) // "CUE" + major
    }

    @Test func rejectsOtherMajor() throws {
        var data = try MeshCodec.encode(Self.envelope(.leave))
        data[3] = UInt8(ProtocolVersion.current.major + 1)
        #expect(throws: MeshCodecError.incompatibleMajor(ProtocolVersion.current.major + 1)) {
            try MeshCodec.decode(data)
        }
    }

    @Test func rejectsBadMagic() {
        #expect(throws: MeshCodecError.malformed) { try MeshCodec.decode(Data([0, 1, 2, 3, 4])) }
        #expect(throws: MeshCodecError.malformed) { try MeshCodec.decode(Data()) }
    }

    /// Minor versions are additive: a newer minor's unknown message type decodes to `.unknown` and is ignored.
    @Test func unknownTypeFromNewerMinorDecodesAsUnknown() throws {
        let json = #"""
        {"version":{"major":1,"minor":9},"sessionID":"11111111-2222-3333-4444-555555555555",
         "sender":"00000000-0000-0000-0000-00000000000A","seq":1,"sentAt":5,
         "message":{"type":"holoProjection","body":{"x":1}}}
        """#
        let env = try MeshCodec.decode(MeshCodec.framed(Data(json.utf8)))
        #expect(env.message == .unknown(type: "holoProjection"))
        #expect(env.version.minor == 9)
    }

    @Test func unknownKeysAreTolerated() throws {
        let json = #"""
        {"version":{"major":1,"minor":0},"sessionID":"11111111-2222-3333-4444-555555555555",
         "sender":"00000000-0000-0000-0000-00000000000A","seq":1,"sentAt":5,"futureField":true,
         "message":{"type":"timePing","body":{"t0":42,"extra":"x"}}}
        """#
        let env = try MeshCodec.decode(MeshCodec.framed(Data(json.utf8)))
        #expect(env.message == .timePing(TimePing(t0: 42)))
    }

    /// Golden fixture for v1. Frozen: if this breaks, the change needs a new major.
    @Test func goldenV1HeartbeatStillDecodes() throws {
        let json = #"""
        {"version":{"major":1,"minor":0},"sessionID":"11111111-2222-3333-4444-555555555555",
         "sender":"00000000-0000-0000-0000-00000000000A","seq":77,"sentAt":-3,
         "message":{"type":"heartbeat","body":{"term":4,"host":"00000000-0000-0000-0000-00000000000B",
         "lastSeq":9,"commitSeq":8,"phase":"inMotion"}}}
        """#
        let env = try MeshCodec.decode(MeshCodec.framed(Data(json.utf8)))
        #expect(env.seq == 77 && env.sentAt == -3)
        #expect(env.message == .heartbeat(Heartbeat(term: 4, host: Self.b, lastSeq: 9, commitSeq: 8,
                                                     phase: .inMotion)))
    }

    @Test func fuzzNeverCrashes() {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<3000 {
            var bytes = [UInt8](repeating: 0, count: Int.random(in: 0..<200, using: &rng))
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
            if Bool.random(using: &rng) && bytes.count >= 4 { bytes[0] = 0x43; bytes[1] = 0x55; bytes[2] = 0x45; bytes[3] = 1 }
            _ = try? MeshCodec.decode(Data(bytes))
        }
    }

    /// A 64 KiB clip chunk must fit comfortably in one MPC reliable send.
    @Test func clipChunkEnvelopeStaysUnderSendLimit() throws {
        let chunk = ClipChunk(shotID: Self.shot, index: 0, total: 1, totalBytes: ClipSender.chunkSize,
                              bytes: Data(repeating: 0xAB, count: ClipSender.chunkSize),
                              sha256: Data(repeating: 1, count: 32))
        let data = try MeshCodec.encode(Self.envelope(.clipChunk(chunk)))
        #expect(data.count < MeshCodec.maxMessageBytes)
    }

    @Test func compatibilityPicksHighestCommonMajor() {
        #expect(ProtocolVersion.negotiate(local: [1, 2, 3], remote: [2, 3, 4]) == 3)
        #expect(ProtocolVersion.negotiate(local: [1], remote: [2]) == nil)
    }
}
