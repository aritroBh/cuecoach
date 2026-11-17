import CoreGraphics
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Drives opt-in recognition consent and multi-sample enrollment into `Recognition.store` (SPEC §2, §5.8, D26, D28).
/// Raw frames are embedded on-device and discarded immediately; only vectors reach `Recognition.store`.
@MainActor @Observable
final class IdentityRegistrationModel {
    enum Step: Equatable { case consent, capturing, done, failed(String) }

    let stack: PersistenceStack
    @ObservationIgnored let faceExtractor: (any EmbeddingExtracting)?
    @ObservationIgnored let bodyExtractor: any EmbeddingExtracting
    @ObservationIgnored var sampleProvider: (@Sendable (RecognitionConsent) async -> RegistrationCapture)?

    var clothesConsent = true
    var faceConsent = false
    private(set) var step: Step = .consent

    var canSelectFace: Bool { faceExtractor?.isIdentityTrained == true }
    var canEnroll: Bool { (clothesConsent || (faceConsent && canSelectFace)) && step != .capturing }

    init(stack: PersistenceStack,
         faceExtractor: (any EmbeddingExtracting)? = FaceEmbeddingExtractor.bundled(),
         bodyExtractor: any EmbeddingExtracting = VisionFeaturePrintExtractor(kind: "body"),
         sampleProvider: (@Sendable (RecognitionConsent) async -> RegistrationCapture)? = nil) {
        self.stack = stack
        self.faceExtractor = faceExtractor
        self.bodyExtractor = bodyExtractor
        self.sampleProvider = sampleProvider
    }

    @discardableResult
    func enroll() async -> Bool {
        let effectiveConsent = RecognitionConsent(clothes: clothesConsent, face: faceConsent && canSelectFace)
        guard effectiveConsent.clothes || effectiveConsent.face else {
            step = .failed("Turn on at least one recognition option.")
            return false
        }
        step = .capturing
        let owner = resolveOrCreateLocalOwner()
        let capture: RegistrationCapture
        if let sampleProvider {
            capture = await sampleProvider(effectiveConsent)
        } else {
            capture = Self.syntheticSamples(for: effectiveConsent)
        }
        let decision = ConsentDecision(consent: effectiveConsent, agreedAt: .now)
        let registrar = RecognitionRegistrar(stack: stack, face: faceExtractor, body: bodyExtractor)
        do {
            try await registrar.register(owner, decision: decision, capture: capture)
            step = .done
            return true
        } catch {
            step = .failed("Couldn't enroll right now. Try again.")
            return false
        }
    }

    private func resolveOrCreateLocalOwner() -> PlayerProfile {
        let ctx = stack.competitiveContext
        if let existing = (try? ctx.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner })))?.first {
            return existing
        }
        let created = PlayerProfile(name: "Player", avatarSymbol: ShellPalette.symbols[0],
                                    avatarColor: ShellPalette.names[1], isLocalOwner: true)
        ctx.insert(created)
        try? ctx.save()
        return created
    }

    /// Deterministic multi-angle sample generator when running without a live camera feed (e.g. Simulator).
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
                    Button("Cancel") { onCompleted(false) }
                        .accessibilityIdentifier("identity.enroll.cancel")
                }
            }
        }
        .tint(AX.accentText)
    }
}
