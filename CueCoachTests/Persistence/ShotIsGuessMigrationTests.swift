import Foundation
import CoreData
import SwiftData
import Testing
import Geometry
import Rules
import Engine
@testable import CueCoach

/// Plan 012 (D43): Competitive V2 → V3 adds `Shot.isGuess`. Old stores must open unchanged.
@MainActor
@Suite struct ShotIsGuessMigrationTests {
    /// Entity version hashes of the shipped V1 and V2 schemas, recorded at 4a50861, before V3 existed. A frozen copy that drifts
    /// changes these, and SwiftData would then fail to recognise a user's store on disk.
    static let v1Hashes =
        "ArchetypeSnapshot=Bi+a97BNCOEF5pzGPnXXoRcKFmb2+LISPbp/fEVO+zs=;Game=4A7glKfH7qB0wF8czU1JOmgMdVUCTzUmYddsLFPZjQU=;Highlight=qP2JznoUVDyzmb5+iXbK4nj/MqXjsk/CdNKz6cfG3DI=;PlayerProfile=2+z29kUzcjp83P/4KJf/FAF2vhC9VsDZPSux1xaMKVA=;RecognitionData=9YQSQblS8RW0hd8esdW4UblFD+ROwm/g0+nPENfNbCY=;Session=alt+pBDlz4+9XVyWtaYSY9/GUgpEAAWbkxhtda4lA7I=;Shot=fPj5LnPT3erKWt4371FXIV6bgof4xB8dodKlpngsgmA="
    static let v2Hashes =
        "ArchetypeSnapshot=Bi+a97BNCOEF5pzGPnXXoRcKFmb2+LISPbp/fEVO+zs=;Game=4A7glKfH7qB0wF8czU1JOmgMdVUCTzUmYddsLFPZjQU=;Highlight=qP2JznoUVDyzmb5+iXbK4nj/MqXjsk/CdNKz6cfG3DI=;PlayerProfile=3UJFD/v/RG8Z7vik4F3NI1ML7VzKRz5wyhBU4WUsSyM=;Session=alt+pBDlz4+9XVyWtaYSY9/GUgpEAAWbkxhtda4lA7I=;Shot=fPj5LnPT3erKWt4371FXIV6bgof4xB8dodKlpngsgmA="

    static func hashes(_ s: any VersionedSchema.Type) -> String {
        let model = NSManagedObjectModel.makeManagedObjectModel(for: s.models)
        guard let model else { return "no model" }
        return model.entityVersionHashesByName.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.base64EncodedString())" }.joined(separator: ";")
    }

    @Test func shippedSchemaHashesNeverChange() {
        #expect(Self.hashes(CompetitiveSchemaV1.self) == Self.v1Hashes)
        #expect(Self.hashes(CompetitiveSchemaV2.self) == Self.v2Hashes)
    }
}
