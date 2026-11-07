import Foundation
import MultipeerConnectivity

/// Multipeer Connectivity transport (SPEC §2, §5.7: "MultipeerConnectivity only").
///
/// - Advertises and browses `_cuecoach._tcp` / `_cuecoach._udp` (both listed in `NSBonjourServices`).
/// - `MCSession` with `encryptionPreference = .required`, at most 8 phones including this one.
/// - The MPC display name is this session's random `PeerID` (no device name, no profile data — TN3213).
/// - Only the lower `PeerID` invites, so two phones never cross-invite into duplicate links.
/// - No back-pressure exists in MPC; `MultipeerMeshSession` paces sends with `OutboundQueue` and
///   `ClipSender` windows its chunks.
///
/// Note: Apple deprecated MPC in Xcode 27 (mesh-identity.md Q1, open). Everything above this type talks to
/// `MeshTransport`, so a Network-framework adapter can replace it without touching the protocol.
final class MPCTransport: NSObject, MeshTransport, @unchecked Sendable {
    static let serviceType = "cuecoach"
    static let maxPeers = 8   // kMCSessionMaximumNumberOfPeers
    static let invitationContext = Data("cuecoach-v1".utf8)

    let localPeer: PeerID
    let events: AsyncStream<TransportEvent>
    let session: MCSession
    private let mcPeer: MCPeerID
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var peers: [PeerID: MCPeerID] = [:]

    init(localPeer: PeerID = PeerID()) {
        self.localPeer = localPeer
        mcPeer = MCPeerID(displayName: localPeer.raw.uuidString)
        session = MCSession(peer: mcPeer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: mcPeer, discoveryInfo: ["v": "\(ProtocolVersion.current.major)"],
                                               serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: mcPeer, serviceType: Self.serviceType)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    // MARK: policy (pure, unit-tested)

    static func shouldInvite(local: PeerID, remote: PeerID, connectedCount: Int) -> Bool {
        local < remote && connectedCount < maxPeers - 1
    }

    static func shouldAccept(connectedCount: Int, context: Data?) -> Bool {
        context == invitationContext && connectedCount < maxPeers - 1
    }

    static func peerID(fromDisplayName name: String) -> PeerID? { UUID(uuidString: name).map(PeerID.init) }

    static func mode(for channel: MeshChannel) -> MCSessionSendDataMode {
        channel == .reliable ? .reliable : .unreliable
    }

    // MARK: MeshTransport

    /// Call from the foreground lobby only (local-network prompt; MPC stops in the background).
    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        continuation.finish()
    }

    func send(_ data: Data, to targets: [PeerID], channel: MeshChannel) throws {
        let mc = lock.withLock { targets.compactMap { peers[$0] } }
        let connected = Set(session.connectedPeers)
        let live = mc.filter { connected.contains($0) }
        guard !live.isEmpty else { return }
        try session.send(data, toPeers: live, with: Self.mode(for: channel))
    }

    private var connectedCount: Int { session.connectedPeers.count }
}

extension MPCTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard let p = Self.peerID(fromDisplayName: peerID.displayName) else { return }
        switch state {
        case .connected:
            lock.withLock { peers[p] = peerID }
            continuation.yield(.connected(p))
        case .notConnected:
            lock.withLock { peers[p] = nil }
            continuation.yield(.disconnected(p))
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let p = Self.peerID(fromDisplayName: peerID.displayName) else { return }
        continuation.yield(.received(data, from: p))
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}

extension MPCTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard let remote = Self.peerID(fromDisplayName: peerID.displayName),
              info?["v"] == "\(ProtocolVersion.current.major)",
              !session.connectedPeers.contains(peerID),
              Self.shouldInvite(local: localPeer, remote: remote, connectedCount: connectedCount) else { return }
        browser.invitePeer(peerID, to: session, withContext: Self.invitationContext, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        continuation.yield(.failed("browse"))
    }
}

extension MPCTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let ok = Self.peerID(fromDisplayName: peerID.displayName) != nil
            && Self.shouldAccept(connectedCount: connectedCount, context: context)
        invitationHandler(ok, ok ? session : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        continuation.yield(.failed("advertise"))
    }
}
