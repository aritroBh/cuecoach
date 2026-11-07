import Foundation

enum TransportEvent: Sendable {
    case connected(PeerID)
    case disconnected(PeerID)
    case received(Data, from: PeerID)
    /// Advertising/browsing failed (e.g. local network permission denied). The game keeps working on one phone.
    case failed(String)
}

/// Byte pipe between phones. Pure plumbing: no game logic, no codec. `MPCTransport` in the app,
/// `MemoryTransport` in tests. A transport only ever talks to peers on the local link (zero network calls).
protocol MeshTransport: AnyObject, Sendable {
    var localPeer: PeerID { get }
    var events: AsyncStream<TransportEvent> { get }
    func start()
    func stop()
    func send(_ data: Data, to peers: [PeerID], channel: MeshChannel) throws
}
