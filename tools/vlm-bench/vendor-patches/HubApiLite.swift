// Offline replacement for swift-transformers' HubApi (CueVLMBench vendor patch).
// Only local-folder loading is supported: no networking, no Crypto/HuggingFace/yyjson dependencies.
import Foundation

public struct HubApi: Sendable {
    public static let shared = HubApi()
    public init() {}

    /// Assumes the file is already present at the local url.
    public func configuration(fileURL: URL) throws -> Config {
        let data = try Data(contentsOf: fileURL)
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [NSString: Any] else {
                throw Hub.HubClientError.configurationMissing(fileURL.lastPathComponent)
            }
            return Config(dict)
        } catch let e as Hub.HubClientError {
            throw e
        } catch {
            throw Hub.HubClientError.jsonSerialization(fileURL: fileURL, message: "\(error)")
        }
    }

    public func snapshot(from repo: Hub.Repo, revision: String = "main", matching globs: [String] = []) async throws -> URL {
        throw Hub.HubClientError.configurationMissing("network disabled in CueVLMBench: \(repo.id)")
    }
}
