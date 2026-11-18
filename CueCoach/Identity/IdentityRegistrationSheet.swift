import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Observation
import SwiftData
import SwiftUI
import Synchronization

/// Drives opt-in recognition consent and multi-sample enrollment into `Recognition.store` (SPEC §2, §5.8, D26, D28).
/// Raw frames are embedded on-device and discarded immediately; only vectors reach `Recognition.store`.
@MainActor @Observable
final class IdentityRegistrationModel {
    enum Step: Equatable { case consent, capturing, done, failed(String) }

    let stack: PersistenceStack
    @ObservationIgnored let faceExtractor: (any EmbeddingExtracting)?
    @ObservationIgnored let bodyExtractor: any EmbeddingExtracting
    @ObservationIgnored var sampleProvider: (@Sendable (RecognitionConsent) async throws -> RegistrationCapture)?

    var clothesConsent = true
    var faceConsent = false
    private(set) var step: Step = .consent
    @ObservationIgnored private var enrollTask: Task<Bool, Never>?
    @ObservationIgnored private var enrollGeneration = 0

    var canSelectFace: Bool { faceExtractor?.isIdentityTrained == true }
    var canEnroll: Bool { (clothesConsent || (faceConsent && canSelectFace)) && step != .capturing }

    init(stack: PersistenceStack,
         faceExtractor: (any EmbeddingExtracting)? = FaceEmbeddingExtractor.bundled().map { AlignedFaceExtractor(embedder: $0) },
         bodyExtractor: any EmbeddingExtracting = VisionFeaturePrintExtractor(kind: "body"),
         sampleProvider: (@Sendable (RecognitionConsent) async throws -> RegistrationCapture)? = nil) {
        self.stack = stack
        self.faceExtractor = faceExtractor
        self.bodyExtractor = bodyExtractor
        self.sampleProvider = sampleProvider
    }

    func cancel() {
        enrollGeneration += 1
        enrollTask?.cancel()
        enrollTask = nil
        if step == .capturing { step = .consent }
    }

    @discardableResult
    func enroll() async -> Bool {
        enrollTask?.cancel()
        enrollGeneration += 1
        let gen = enrollGeneration
        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performEnrollment(generation: gen)
        }
        enrollTask = task
        let ok = await task.value
        if enrollGeneration == gen { enrollTask = nil }
        return ok
    }

    private func performEnrollment(generation gen: Int) async -> Bool {
        let effectiveConsent = RecognitionConsent(clothes: clothesConsent, face: faceConsent && canSelectFace)
        guard effectiveConsent.clothes || effectiveConsent.face else {
            step = .failed("Turn on at least one recognition option.")
            return false
        }
        guard let owner = existingLocalOwner() else {
            step = .failed("Create your profile first in Profile.")
            return false
        }
        step = .capturing
        do {
            let capture: RegistrationCapture
            if let sampleProvider {
                capture = try await sampleProvider(effectiveConsent)
            } else {
                #if targetEnvironment(simulator)
                capture = Self.syntheticSamples(for: effectiveConsent)
                #else
                capture = try await DeviceRegistrationCamera.captureSamples(
                    for: effectiveConsent, count: RecognitionRegistrar.minSamples)
                #endif
            }
            guard !Task.isCancelled, enrollGeneration == gen else {
                if enrollGeneration == gen, step == .capturing { step = .consent }
                return false
            }
            let decision = ConsentDecision(consent: effectiveConsent, agreedAt: .now)
            let registrar = RecognitionRegistrar(
                stack: stack, face: faceExtractor, body: bodyExtractor,
                save: { [weak self] ctx in
                    guard let self, !Task.isCancelled, self.enrollGeneration == gen else {
                        throw CancellationError()
                    }
                    try ctx.save()
                })
            try await registrar.register(owner, decision: decision, capture: capture)
            step = .done
            return true
        } catch is CancellationError {
            if enrollGeneration == gen, step == .capturing { step = .consent }
            return false
        } catch DeviceRegistrationCamera.CaptureError.permissionDenied {
            if enrollGeneration == gen { step = .failed("Camera permission is needed to enroll.") }
            return false
        } catch {
            if enrollGeneration == gen { step = .failed("Couldn't enroll right now. Try again.") }
            return false
        }
    }

    private func existingLocalOwner() -> PlayerProfile? {
        let ctx = stack.competitiveContext
        return (try? ctx.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner })))?.first
    }

    #if targetEnvironment(simulator)
    static func syntheticSamples(for consent: RecognitionConsent) -> RegistrationCapture {
        let count = RecognitionRegistrar.minSamples
        let bodies = consent.clothes ? (0..<count).compactMap { makeSampleImage(seed: 10 + $0) } : []
        let faces = consent.face ? (0..<count).compactMap { makeSampleImage(seed: 40 + $0) } : []
        return RegistrationCapture(faceImages: faces, bodyImages: bodies)
    }

    nonisolated static func makeSampleImage(seed: Int, size: Int = 112) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let o = (y * size + x) * 4
                pixels[o] = UInt8((x * 3 + seed * 17) & 0xFF)
                pixels[o + 1] = UInt8((y * 5 + seed * 11) & 0xFF)
                pixels[o + 2] = UInt8(((x + y) * 2 + seed * 7) & 0xFF)
                pixels[o + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
    #endif
}

/// Real front/back camera multi-frame capture for physical iPhone enrollment (never writes images to disk).
enum DeviceRegistrationCamera {
    enum CaptureError: Error { case permissionDenied, cameraUnavailable, insufficientFrames }

    static func captureSamples(for consent: RecognitionConsent, count: Int) async throws -> RegistrationCapture {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CaptureError.permissionDenied }
        } else if status != .authorized {
            throw CaptureError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            throw CaptureError.cameraUnavailable
        }

        let collector = SampleFrameCollector(targetCount: count)
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        let queue = DispatchQueue(label: "cuecoach.identity.enroll")
        output.setSampleBufferDelegate(collector, queue: queue)

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureError.cameraUnavailable
        }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        defer { session.stopRunning() }

        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline && collector.frames.count < count {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(120))
        }
        try Task.checkCancellation()
        let captured = collector.frames
        guard captured.count >= count else { throw CaptureError.insufficientFrames }
        return RegistrationCapture(
            faceImages: consent.face ? captured : [],
            bodyImages: consent.clothes ? captured : [])
    }

    private final class SampleFrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let targetCount: Int
        private let lock = Mutex((frames: [CGImage](), lastTime: 0.0))

        init(targetCount: Int) { self.targetCount = targetCount }

        var frames: [CGImage] { lock.withLock { $0.frames } }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let shouldTake = lock.withLock { state -> Bool in
                guard state.frames.count < targetCount, now - state.lastTime >= 0.18 else { return false }
                state.lastTime = now
                return true
            }
            guard shouldTake,
                  let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let px = PixelImage(pixelBuffer: pb, maxWidth: 480),
                  let cg = px.makeCGImage() else { return }
            lock.withLock { if $0.frames.count < targetCount { $0.frames.append(cg) } }
        }
    }
}

struct IdentityRegistrationSheet: View {
    @Bindable var model: IdentityRegistrationModel
    let onCompleted: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AX.space.s5) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("On-device shooter recognition", systemImage: "person.crop.circle.badge.checkmark")
                            .axFont(.subtitle)
                            .foregroundStyle(AX.ink)
                        Text("Stores compact vectors on this phone only so CueCoach can credit your shots automatically. Photos are never saved or backed up, and you can delete everything in one tap.")
                            .axFont(.body)
                            .foregroundStyle(AX.inkMuted)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))

                    VStack(spacing: 0) {
                        Toggle(isOn: $model.clothesConsent) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Session appearance").axFont(.body).foregroundStyle(AX.ink)
                                Text("Matches your shirt & posture during a game.").axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                            }
                        }
                        .padding(16)
                        .frame(minHeight: 56)
                        .accessibilityIdentifier("identity.consent.clothes")

                        if model.canSelectFace {
                            Divider().overlay(AX.border)
                            Toggle(isOn: $model.faceConsent) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Face template").axFont(.body).foregroundStyle(AX.ink)
                                    Text("Recognizes you across sessions.").axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                                }
                            }
                            .padding(16)
                            .frame(minHeight: 56)
                            .accessibilityIdentifier("identity.consent.face")
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))

                    if case .failed(let message) = model.step {
                        Text(message)
                            .axFont(.label, weight: .semibold)
                            .foregroundStyle(AX.danger)
                            .accessibilityIdentifier("identity.enroll.error")
                    }

                    Button {
                        Task {
                            let ok = await model.enroll()
                            if ok { onCompleted(true) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if model.step == .capturing {
                                ProgressView().tint(AX.onAccent)
                            } else {
                                Image(systemName: "checkmark.shield.fill")
                            }
                            Text(model.step == .capturing ? "Enrolling…" : "Agree & Enroll")
                                .axFont(.headline)
                        }
                        .foregroundStyle(AX.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(model.canEnroll ? AX.accent : AX.neutral))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canEnroll)
                    .accessibilityIdentifier("identity.enroll.agree")
                }
                .padding(16)
            }
            .background(AX.page.ignoresSafeArea())
            .navigationTitle("Recognize Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancel()
                        onCompleted(false)
                    }
                    .accessibilityIdentifier("identity.enroll.cancel")
                }
            }
        }
        .tint(AX.accentText)
        .onDisappear {
            if model.step != .done {
                model.cancel()
            }
        }
    }
}
