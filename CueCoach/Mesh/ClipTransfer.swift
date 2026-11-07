import Foundation

/// Sends one clip in SHA-tagged chunks over `.reliable` with an app-level window (D3, mesh-identity.md §2.7).
struct ClipSender: Sendable {
    /// 64 KiB per chunk keeps one envelope well under `MeshCodec.maxMessageBytes`.
    static let chunkSize = 64 * 1024
}
