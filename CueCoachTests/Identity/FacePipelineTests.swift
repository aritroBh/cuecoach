import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

// D25: Vision 5-point alignment to the ArcFace 112×112 template, quality gates, AuraFace extractor, ship gate (F4–F6).

private func near(_ a: CGPoint, _ b: CGPoint, _ tol: Double = 1e-6) -> Bool {
    abs(Double(a.x - b.x)) <= tol && abs(Double(a.y - b.y)) <= tol
}

@Suite struct FaceAlignmentTests {
    let t = FaceAlignment.arcface112

    @Test func templateIsTheStandardArcFaceFivePoints() {
        #expect(t.count == 5)
        #expect(near(t[0], CGPoint(x: 38.2946, y: 51.6963), 1e-3))
        #expect(near(t[4], CGPoint(x: 70.7299, y: 92.2041), 1e-3))
    }

    @Test func identityPointsGiveTheIdentityTransform() throws {
        let m = try #require(FaceAlignment.similarity(from: t, to: t))
        for p in t { #expect(near(p.applying(m), p, 1e-6)) }
    }

    @Test func recoversRotationScaleAndTranslation() throws {
        let truth = CGAffineTransform(rotationAngle: 0.4).scaledBy(x: 2.5, y: 2.5).translatedBy(x: 40, y: -12)
        let src = t.map { $0.applying(truth.inverted()) }
        let m = try #require(FaceAlignment.similarity(from: src, to: t))
        for (s, d) in zip(src, t) { #expect(near(s.applying(m), d, 1e-6)) }
    }

    @Test func degenerateInputGivesNil() {
        #expect(FaceAlignment.similarity(from: Array(repeating: CGPoint(x: 3, y: 3), count: 5), to: t) == nil)
        #expect(FaceAlignment.similarity(from: [CGPoint(x: 1, y: 1)], to: [CGPoint(x: 1, y: 1)]) == nil)
        #expect(FaceAlignment.similarity(from: t, to: Array(t.prefix(4))) == nil)
    }

    @Test func fivePointsFromLandmarkRegionsAreOrderedByImageSide() throws {
        // Regions in top-left pixel space; eyes / mouth corners given in "wrong" order on purpose.
        let five = try #require(FaceLandmarks5(eyeA: [CGPoint(x: 70, y: 50), CGPoint(x: 74, y: 52)],
                                               eyeB: [CGPoint(x: 36, y: 50), CGPoint(x: 40, y: 52)],
                                               nose: [CGPoint(x: 55, y: 70), CGPoint(x: 57, y: 74)],
                                               outerLips: [CGPoint(x: 56, y: 88), CGPoint(x: 71, y: 92), CGPoint(x: 41, y: 92), CGPoint(x: 56, y: 96)]))
        #expect(near(five.points[0], CGPoint(x: 38, y: 51)))
        #expect(near(five.points[1], CGPoint(x: 72, y: 51)))
        #expect(near(five.points[2], CGPoint(x: 56, y: 72)))
        #expect(near(five.points[3], CGPoint(x: 41, y: 92)))
        #expect(near(five.points[4], CGPoint(x: 71, y: 92)))
        #expect(abs(five.interOcular - 34) < 1e-9)
        #expect(FaceLandmarks5(eyeA: [], eyeB: [CGPoint.zero], nose: [.zero], outerLips: [.zero, .zero]) == nil)
    }

    @Test func warpPutsSourceLandmarksOnTheTemplate() throws {
        // A 400×300 frame with bright dots at five source points (a rotated, scaled, shifted face).
        // template → frame: centre on (200, 150), rotate, ×2 (all points well inside the 400×300 frame)
        let truth = CGAffineTransform(translationX: 200, y: 150).rotated(by: 0.3).scaledBy(x: 2, y: 2).translatedBy(x: -56, y: -72)
        let src = t.map { $0.applying(truth) }
        let img = try #require(dotImage(width: 400, height: 300, dots: [src[0]]))
        let m = try #require(FaceAlignment.similarity(from: src, to: t))
        let out = try #require(FaceAlignment.warp(img, transform: m))
        #expect(out.width == 112 && out.height == 112)
        let c = try #require(brightCentroid(out))
        #expect(near(c, t[0], 2.5), "dot landed at \(c), want \(t[0])")
    }
}

@Suite struct FaceQualityGateTests {
    let g = FaceQualityGate.standard

    @Test func admitsAGoodFrontalFace() {
        #expect(g.admits(interOcularPixels: 40, yawDegrees: 10, rollDegrees: -5, quality: 0.7))
    }

    @Test func rejectsSmallTurnedTiltedOrPoorFaces() {
        #expect(!g.admits(interOcularPixels: 18, yawDegrees: 0, rollDegrees: 0, quality: 0.9))
        #expect(!g.admits(interOcularPixels: 40, yawDegrees: 50, rollDegrees: 0, quality: 0.9))
        #expect(!g.admits(interOcularPixels: 40, yawDegrees: -50, rollDegrees: 0, quality: 0.9))
        #expect(!g.admits(interOcularPixels: 40, yawDegrees: 0, rollDegrees: 40, quality: 0.9))
        #expect(!g.admits(interOcularPixels: 40, yawDegrees: 0, rollDegrees: 0, quality: 0.2))
        #expect(!g.admits(interOcularPixels: 40, yawDegrees: 0, rollDegrees: 0, quality: nil))
    }
}

@Suite struct FaceModelTests {
    @Test func genericFeaturePrintIsNotAnIdentityModel() {
        #expect(!VisionFeaturePrintExtractor(kind: "face").isIdentityTrained)
        #expect(FaceEmbeddingExtractor.modelID == "fal.auraface.v1.fp16")
    }

    @Test func missingModelFileMeansNoExtractor() {
        #expect(FaceEmbeddingExtractor.load(from: URL(fileURLWithPath: "/nonexistent/FaceEmbedding.mlmodelc")) == nil)
    }

    @Test func analyzerHasNoFaceEmbedderByDefault() {
        // F5: no generic feature print on faces. Face embedding exists only when the AuraFace model is installed.
        #expect(VisionPersonAnalyzer().face == nil)
    }

    @MainActor @Test func registrarRefusesFaceConsentWithAGenericModel() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner()
        stack.competitiveContext.insert(owner); try stack.competitiveContext.save()
        let imgs = (0..<4).map { _ in testImage(width: 8) }
        let reg = RecognitionRegistrar(stack: stack, face: VisionFeaturePrintExtractor(kind: "face"),
                                       body: VisionFeaturePrintExtractor(kind: "body"))
        await #expect(throws: RegistrationError.faceModelUnavailable) {
            try await reg.register(owner, decision: ConsentDecision(consent: .init(clothes: false, face: true), agreedAt: .now),
                                   capture: RegistrationCapture(faceImages: imgs, bodyImages: []))
        }
        let none = RecognitionRegistrar(stack: stack, face: nil, body: VisionFeaturePrintExtractor(kind: "body"))
        await #expect(throws: RegistrationError.faceModelUnavailable) {
            try await none.register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: true), agreedAt: .now),
                                    capture: RegistrationCapture(faceImages: imgs, bodyImages: imgs))
        }
        #expect(owner.recognition == nil)
    }

    /// Runs only where `fetch_auraface.sh` installed the model into the app bundle (never in CI / a fresh clone).
    @Test(.enabled(if: FaceEmbeddingExtractor.bundled() != nil, "AuraFace model not installed (tools/faceid/fetch_auraface.sh)"))
    func bundledModelGivesAUnitLength512Vector() async throws {
        let x = try #require(FaceEmbeddingExtractor.bundled())
        let img = try #require(dotImage(width: 112, height: 112, dots: [CGPoint(x: 56, y: 56)]))
        let e = try await x.embedding(of: img)
        #expect(e.modelID == FaceEmbeddingExtractor.modelID && e.vector.count == 512)
        let norm = e.vector.reduce(0) { $0 + Double($1 * $1) }.squareRoot()
        #expect(abs(norm - 1) < 1e-3)
        let clock = ContinuousClock()
        let n = 10
        let dt = try await clock.measure { for _ in 0..<n { _ = try await x.embedding(of: img) } }
        let ms = Double(dt.components.attoseconds) / 1e15 / Double(n) + Double(dt.components.seconds) * 1000 / Double(n)
        print("FACE-EMBED-MS per face (\(x.computeUnitsDescription)): \(String(format: "%.1f", ms))")
    }
}

@Suite struct FaceShipGateTests {
    @Test func tarAtFarPicksTheThresholdFromImpostors() throws {
        let impostor = (0..<1000).map { Double($0) / 1000 }          // 0.000 … 0.999
        let genuine = [0.9995, 0.9999, 0.5, 0.998]
        let r = try #require(FaceBenchmark.tarAtFAR(genuine: genuine, impostor: impostor, far: 1e-3))
        #expect(abs(r.threshold - 0.998) < 1e-12)                    // one false accept (0.999) allowed
        #expect(abs(r.tar - 0.5) < 1e-12)                            // 0.9995 and 0.9999 pass; 0.998 does not
    }

    @Test func tooFewImpostorPairsCannotResolveTheFAR() {
        #expect(FaceBenchmark.tarAtFAR(genuine: [0.9], impostor: Array(repeating: 0.1, count: 500), far: 1e-3) == nil)
    }

    @Test func gatePassesOnlyWithEnoughSubjectsAndHighTAR() {
        var rng = SystemRandomNumberGenerator()
        func subjects(_ n: Int, spread: Float) -> [[Embedding]] {
            (0..<n).map { i in (0..<12).map { _ in
                var v = [Float](repeating: 0, count: 64); v[i] = 1
                for k in v.indices { v[k] += Float.random(in: -spread...spread, using: &rng) }
                return Embedding(modelID: "m", vector: v).normalised!
            } }
        }
        let good = FaceBenchmark.evaluate(subjects: HeldOutShipGateTests.subjects(20, spread: 0.05), modelID: "m")
        guard case .pass(let record) = good else { Issue.record("expected pass, got \(good)"); return }
        #expect(record.modelID == "m" && record.tar >= FaceBenchmark.requiredTAR && record.far == 1e-3)
        #expect(FaceBenchmark.evaluate(subjects: HeldOutShipGateTests.subjects(4, spread: 0.05), modelID: "m") == .insufficientData)
        // Everybody looks alike → impostors score like genuines → fail.
        let blur = FaceBenchmark.evaluate(subjects: HeldOutShipGateTests.subjects(20, spread: 2.0), modelID: "m")
        if case .pass = blur { Issue.record("noise must not pass") }
    }

    @Test func faceMatchingStaysOffUntilTheGatePassesForThatModel() async {
        let snap = IdentitySnapshot(roster: IdentityRoster(entries: [RosterEntry(playerID: Synth.a, consent: .init(clothes: false, face: true)),
                                                                     RosterEntry(playerID: Synth.b, consent: .init(clothes: false, face: true))]),
                                    appearanceGallery: [:], faceGallery: [Synth.a: [Synth.axis(2, model: faceModel)]])
        let people = [ObservedPerson(box: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.25),
                                     joints: BodyJoints(points: [.neck: CGPoint(x: 0.45, y: 0.42), .root: CGPoint(x: 0.25, y: 0.40),
                                                                 .leftWrist: CGPoint(x: 0.49, y: 0.31)]),
                                     face: Synth.axis(2, model: faceModel), faceQuality: 0.9)]
        let w = StrokeWindow(frames: [IdentityFrame(image: testImage(width: 1), cueBall: CGPoint(x: 0.5, y: 0.3))])
        let closed = FakeAnalyzer(script: [1: people])
        _ = await VisionShooterIdentifier(analyzer: closed, faceMatching: .shooterOnly, faceGate: nil)
            .identify(w, snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(closed.wants.allSatisfy { !$0.face })
        let other = FakeAnalyzer(script: [1: people])
        _ = await VisionShooterIdentifier(analyzer: other, faceMatching: .shooterOnly, faceGate: .testPass(modelID: "another.model"))
            .identify(w, snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(other.wants.allSatisfy { !$0.face })
        let open = FakeAnalyzer(script: [1: people])
        _ = await VisionShooterIdentifier(analyzer: open, faceMatching: .shooterOnly, faceGate: .testPass(modelID: faceModel))
            .identify(w, snapshot: snap, expectedShooter: Synth.a, teamInTurn: nil)
        #expect(open.wants.allSatisfy { $0.face })
    }

    @MainActor @Test func benchmarkHoldsOnlyRAMAndForgetsOnWithdrawAndEnd() {
        let bench = FaceBenchmarkSession(modelID: "m")
        let ok = FaceBenchConsent(agreedAt: .now)
        let s1 = bench.addSubject([Synth.axis(1, model: "m"), Synth.axis(1, model: "m")], consent: ok)!
        _ = bench.addSubject([Synth.axis(2, model: "m"), Synth.axis(2, model: "wrong.model")], consent: ok)
        #expect(bench.subjectCount == 2 && bench.embeddingCount == 3)   // other models are never mixed in
        bench.withdraw(s1)
        #expect(bench.subjectCount == 1)
        bench.deleteAll()
        #expect(bench.subjectCount == 0 && bench.embeddingCount == 0)
    }

    @Test func gateRecordStoresOnlyAggregates() throws {
        let r = FaceShipGateRecord.testPass(modelID: "m")
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        for key in ["vector", "embedding", "["] { #expect(!json.lowercased().contains(key)) }   // no lists, no vectors
    }
}

// MARK: - helpers

/// Black RGBA image with 5×5 white dots at top-left pixel coordinates.
func dotImage(width: Int, height: Int, dots: [CGPoint]) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(gray: 1, alpha: 1)
    for d in dots { ctx.fill(CGRect(x: d.x - 2.5, y: CGFloat(height) - d.y - 2.5, width: 5, height: 5)) }
    return ctx.makeImage()
}

/// Centroid (top-left pixel coordinates) of bright pixels.
func brightCentroid(_ img: CGImage) -> CGPoint? {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in 0..<h { for x in 0..<w {
        let v = Double(buf[(y * w + x) * 4])
        if v > 64 { sx += (Double(x) + 0.5) * v; sy += (Double(y) + 0.5) * v; n += v }
    } }
    return n > 0 ? CGPoint(x: sx / n, y: sy / n) : nil
}

extension FaceShipGateRecord {
    /// Test-only passing record (never in the app target).
    static func testPass(modelID: String) -> FaceShipGateRecord {
        FaceShipGateRecord(modelID: modelID, threshold: 0.4, tar: 0.95, tarLower95: 0.93, far: 1e-3, fpir: 0, fpirUpper95: 0.01,
                           misidentifications: 0, misidentificationUpper95: 0.01, coverage: 0.95, folds: 3,
                           calibrationSubjects: 10, reportSubjects: 10, subjectCount: 20, passedAt: Date(timeIntervalSince1970: 0))
    }
}
