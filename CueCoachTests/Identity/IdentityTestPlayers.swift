import Foundation
@testable import CueCoach

/// Test stand-in for "a profile and its stored templates". Templates now live in the recognition store, not on
/// `PlayerProfile`, so session tests that only need a roster build these instead of SwiftData rows.
final class TestPlayer {
    let id: UUID
    var recognition: StoredRecognitionTemplates?
    init(id: UUID, name: String = "P", avatarSymbol: String = "star", avatarColor: String = "red",
         isSessionGuest: Bool = false) {
        self.id = id
    }
}

extension IdentitySession {
    convenience init(profiles: [TestPlayer], guests: [UUID] = [], faceModelID: String, bodyModelID: String) {
        self.init(players: profiles.map { ($0.id, $0.recognition) }, guests: guests,
                  faceModelID: faceModelID, bodyModelID: bodyModelID)
    }
}

extension IdentitySession {
    func addPlayer(_ p: TestPlayer) { addPlayer(id: p.id, stored: p.recognition) }
}
