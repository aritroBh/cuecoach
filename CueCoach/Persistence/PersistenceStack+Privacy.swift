import Foundation
import SwiftData

extension PersistenceStack {
    /// Settings → "Delete my recognition data": removes the local owner's face/appearance embeddings
    /// in one call. The profile, games and stats are untouched.
    func deleteMyRecognitionData() throws {
        let ctx = competitiveContext
        let owners = try ctx.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        for owner in owners {
            if let r = owner.recognition {
                owner.recognition = nil
                ctx.delete(r)
            }
        }
        try ctx.save()
    }

    /// Session end: drop every peer profile cached for the session (cascade removes their embeddings).
    /// Shots keep the guest's `shooterID` as plain history.
    func purgeSessionGuests() throws {
        let ctx = competitiveContext
        try ctx.delete(model: PlayerProfile.self, where: #Predicate { $0.isSessionGuest })
        try ctx.save()
    }
}
