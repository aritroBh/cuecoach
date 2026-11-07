import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

@Suite struct VisionAdapterTests {
    @Test func floatAndDoubleBuffersDecode() {
        let f: [Float] = [1, 2, 3]
        #expect(VisionFeaturePrintExtractor.floats(f.withUnsafeBytes { Data($0) }, type: .float, count: 3) == f)
        let d: [Double] = [0.5, -1]
        #expect(VisionFeaturePrintExtractor.floats(d.withUnsafeBytes { Data($0) }, type: .double, count: 2) == [0.5, -1])
    }

    @Test func faceAndBodyModelIDsDiffer() {
        #expect(VisionFeaturePrintExtractor(kind: "face").modelID != VisionFeaturePrintExtractor(kind: "body").modelID)
    }

    @Test func cropFlipsLowerLeftNormalisedToTopLeftPixels() throws {
        let img = testImage(width: 100, height: 200)
        // Bottom-left quarter in Vision space = bottom rows in pixel space.
        let c = try #require(VisionPersonAnalyzer.crop(img, CGRect(x: 0, y: 0, width: 0.5, height: 0.25)))
        #expect(c.width == 50 && c.height == 50)
        #expect(VisionPersonAnalyzer.crop(img, CGRect(x: 2, y: 2, width: 1, height: 1)) == nil)       // off-image
        #expect(VisionPersonAnalyzer.crop(img, CGRect(x: 0, y: 0, width: 0.01, height: 0.01)) == nil) // too small
    }

    @Test func boxAndUpperBodyComeFromJoints() throws {
        let j = BodyJoints(points: [.neck: CGPoint(x: 0.5, y: 0.8), .root: CGPoint(x: 0.5, y: 0.5),
                                    .leftShoulder: CGPoint(x: 0.4, y: 0.8), .rightShoulder: CGPoint(x: 0.6, y: 0.8),
                                    .leftWrist: CGPoint(x: 0.3, y: 0.4)])
        let box = try #require(VisionPersonAnalyzer.box(j))
        #expect(box.minX < 0.3 && box.maxX > 0.6 && box.minY < 0.4 && box.maxY > 0.8)
        let ub = try #require(VisionPersonAnalyzer.upperBody(j))
        #expect(ub.minY > 0.45 && ub.minX > 0.35)
        #expect(VisionPersonAnalyzer.box(BodyJoints(points: [.neck: .zero])) == nil)
        #expect(VisionPersonAnalyzer.upperBody(BodyJoints(points: [.neck: .zero])) == nil)
    }

    @Test(.enabled(if: VisionAdapterTests.featurePrintAvailable, "Vision needs a compute device (real iPhone)"))
    func analyzerFindsNobodyInAnEmptyFrame() async throws {
        let people = try await VisionPersonAnalyzer().people(in: testImage(width: 64, height: 64),
                                                            wants: AnalysisWants(appearance: true, face: true))
        #expect(people.isEmpty)
    }

    @Test(.enabled(if: VisionAdapterTests.featurePrintAvailable, "Vision needs a compute device (real iPhone)"))
    func realFeaturePrintIsStableForTheSameImage() async throws {
        let x = VisionFeaturePrintExtractor(kind: "body")
        let img = testImage(width: 64, height: 64)
        let a = try await x.embedding(of: img), b = try await x.embedding(of: img)
        #expect(a.vector.count > 16)
        #expect((a.cosine(b) ?? 0) > 0.999)
        #expect(a.modelID == x.modelID)
    }

    /// The iOS 27 simulator reports "No available compute device for VNComputeStageMain"; probe once.
    static let featurePrintAvailable: Bool = {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        Task.detached {
            ok = (try? await VisionFeaturePrintExtractor(kind: "probe").embedding(of: testImage(width: 64, height: 64))) != nil
            sem.signal()
        }
        sem.wait()
        return ok
    }()
}
