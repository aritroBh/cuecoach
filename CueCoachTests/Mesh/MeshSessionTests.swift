import Foundation
import MultipeerConnectivity
import Testing
@testable import CueCoach

/// In-process transport hub: real async delivery between `MemoryTransport`s, no radio.
final class MemoryHub: @unchecked Sendable {
    private let lock = NSLock()
    private var members: [PeerID: MemoryTransport] = [:]

    func join(_ t: MemoryTransport) {
        let others: [MemoryTransport] = lock.withLock {
            let o = Array(members.values)
            members[t.localPeer] = t
            return o
        }
        for o in others {
            o.emit(.connected(t.localPeer))
            t.emit(.connected(o.localPeer))
        }
    }

    /// Abrupt death: no goodbye, others just stop hearing it (like a force-quit host).
    func kill(_ p: PeerID) { lock.withLock { members[p]?.dead = true; members[p] = nil } }

    func deliver(_ data: Data, from: PeerID, to: [PeerID]) {
        let targets = lock.withLock { to.compactMap { members[$0] } }
        for t in targets where !t.dead { t.emit(.received(data, from: from)) }
    }
}

final class MemoryTransport: MeshTransport, @unchecked Sendable {
    let localPeer: PeerID
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let hub: MemoryHub
    var dead = false
    private(set) var sentCount = 0

    init(hub: MemoryHub, id: PeerID = PeerID()) {
        localPeer = id
        self.hub = hub
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    func emit(_ e: TransportEvent) { continuation.yield(e) }
    func start() { hub.join(self) }
    func stop() { continuation.finish() }
    func send(_ data: Data, to peers: [PeerID], channel: MeshChannel) throws {
        guard !dead else { return }
        sentCount += 1
        hub.deliver(data, from: localPeer, to: peers)
    }
}

func waitUntil(_ timeout: Double = 5, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await cond()
}

@Suite(.serialized) struct MeshSessionTests {
    static var fast: MeshConfig {
        var c = MeshConfig()
        c.discoveryWindow = 0.3
        c.heartbeatInterval = 0.05
        c.failTimeout = 0.6
        return c
    }

    static func session(_ hub: MemoryHub, device: Int) -> (MultipeerMeshSession, MemoryTransport) {
        let t = MemoryTransport(hub: hub)
        let s = MultipeerMeshSession(transport: t, status: PeerStatus(deviceClass: device, batteryPercent: 80,
                                                                       onPower: false), config: fast)
        return (s, t)
    }

    @Test func onePhoneSessionHostsAlone() async {
        let hub = MemoryHub()
        let (s, _) = Self.session(hub, device: 16)
        await s.start()
        #expect(await waitUntil { await s.snapshot().role == .host })
        await s.append(.ruleSetChosen(.wpaNine))
        #expect(await waitUntil { await s.snapshot().commitSeq == 1 })
        await s.stop()
    }

    @Test func twoSessionsFormMeshAndReplicate() async {
        let hub = MemoryHub()
        let (a, _) = Self.session(hub, device: 16)
        let (b, _) = Self.session(hub, device: 18)
        await a.start()
        await b.start()
        #expect(await waitUntil {
            let (ra, rb) = (await a.snapshot().role, await b.snapshot().role)
            return rb == .host && ra == .client(host: b.localPeer)
        })
        await a.append(.ruleSetChosen(.wpaEight))     // client proposal → host log → replicated
        #expect(await waitUntil {
            let la = await a.snapshot().log.count
            let cb = await b.snapshot().commitSeq
            return la == 1 && cb == 1
        })
        await a.stop()
        await b.stop()
    }

    @Test func killingHostSessionKeepsGame() async {
        let hub = MemoryHub()
        let sessions = (0..<3).map { Self.session(hub, device: 15 + $0) }
        for (s, _) in sessions { await s.start() }
        let host = sessions[2].0
        #expect(await waitUntil { let snap = await host.snapshot(); return snap.role == .host && snap.roster.count == 3 })
        await host.append(.ruleSetChosen(.wpaNine))
        #expect(await waitUntil { await sessions[0].0.snapshot().log.count == 1 })
        hub.kill(host.localPeer)
        await host.stop()
        let next = sessions[1].0
        #expect(await waitUntil(3) { await next.snapshot().role == .host })
        #expect(await next.snapshot().log.map(\.event) == [.ruleSetChosen(.wpaNine)])
        await next.append(.ruleSetChosen(.barEight))
        #expect(await waitUntil { await sessions[0].0.snapshot().log.count == 2 })
        for (s, _) in sessions { await s.stop() }
    }

    @Test func updatesStreamReportsRoleChange() async {
        let hub = MemoryHub()
        let (s, _) = Self.session(hub, device: 16)
        let stream = s.updates
        await s.start()
        let got = await withTaskGroup(of: Bool.self) { g in
            g.addTask {
                for await u in stream { if case .roleChanged(.host, _) = u { return true } }
                return false
            }
            g.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let r = await g.next()!
            g.cancelAll()
            return r
        }
        #expect(got)
        await s.stop()
    }

    @Test func undecodableBytesAreCountedNotFatal() async {
        let hub = MemoryHub()
        let (s, t) = Self.session(hub, device: 16)
        await s.start()
        t.emit(.received(Data([1, 2, 3]), from: PeerID()))
        #expect(await waitUntil { await s.snapshot().undecodable == 1 })
        #expect(await s.snapshot().role != .client(host: PeerID()))
        await s.stop()
    }
}

/// Multipeer Connectivity adapter: configuration that can be checked without a radio.
@Suite struct MPCTransportTests {
    @Test func serviceTypeIsValidAndMatchesInfoPlist() throws {
        let type = MPCTransport.serviceType
        #expect((1...15).contains(type.count))
        #expect(type.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        let services = try #require(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        #expect(services.contains("_\(type)._tcp"))
        #expect(services.contains("_\(type)._udp"))
        let why = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        #expect(!(why ?? "").isEmpty)
    }

    @Test func sessionRequiresEncryption() {
        let t = MPCTransport(localPeer: PeerID())
        #expect(t.session.encryptionPreference == .required)
        #expect(t.session.myPeerID.displayName == t.localPeer.raw.uuidString)
    }

    @Test func maxEightPeersIncludingMe() {
        #expect(MPCTransport.maxPeers == 8)
        let ctx = MPCTransport.invitationContext(sessionTag: 3)
        #expect(MPCTransport.shouldAccept(connectedCount: 6, context: ctx, sessionTag: 3))
        #expect(!MPCTransport.shouldAccept(connectedCount: 7, context: ctx, sessionTag: 3))
        #expect(!MPCTransport.shouldAccept(connectedCount: 0, context: Data("other-app".utf8), sessionTag: 3))
        #expect(!MPCTransport.shouldAccept(connectedCount: 0, context: nil, sessionTag: 3))
    }

    /// Only the lower PeerID invites, so two phones never cross-invite into duplicate links.
    @Test func exactlyOneSideInvites() {
        let a = PeerID(), b = PeerID()
        #expect(MPCTransport.shouldInvite(local: a, remote: b, connectedCount: 0)
                != MPCTransport.shouldInvite(local: b, remote: a, connectedCount: 0))
        let low = min(a, b), high = max(a, b)
        #expect(!MPCTransport.shouldInvite(local: low, remote: high, connectedCount: 7))
        #expect(!MPCTransport.shouldInvite(local: low, remote: low, connectedCount: 0))
    }

    @Test func peerIDRoundTripsThroughDisplayName() {
        let p = PeerID()
        #expect(MPCTransport.peerID(fromDisplayName: p.raw.uuidString) == p)
        #expect(MPCTransport.peerID(fromDisplayName: "Aritro's iPhone") == nil)
    }

    @Test func channelMapsToSendMode() {
        #expect(MPCTransport.mode(for: .reliable) == .reliable)
        #expect(MPCTransport.mode(for: .unreliable) == .unreliable)
    }
}
