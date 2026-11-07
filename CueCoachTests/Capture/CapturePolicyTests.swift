import Foundation
import Testing
@testable import CueCoach

struct CapturePolicyTests {
    typealias F = CapturePolicy.Format
    let formats = [F(width: 3840, height: 2160, fps: 30), F(width: 1920, height: 1440, fps: 60),
                   F(width: 1920, height: 1080, fps: 60), F(width: 1280, height: 720, fps: 60),
                   F(width: 1920, height: 1080, fps: 30)]

    @Test func coolDevicePrefers4K() {
        #expect(CapturePolicy.choose(formats, tier: .max)?.width == 3840)
        #expect(CapturePolicy.choose(formats, tier: .max, fourK: F(width: 3840, height: 2160, fps: 30))?.width == 3840)
    }

    @Test func no4KFallsBackToBest60() {
        let f = formats.filter { $0.width < 3840 }
        #expect(CapturePolicy.choose(f, tier: .max) == F(width: 1920, height: 1440, fps: 60))
    }

    @Test func seriousThermalDropsBelow4KAndKeeps60() {
        #expect(CapturePolicy.choose(formats, tier: .sustained) == F(width: 1920, height: 1440, fps: 60))
    }

    @Test func criticalUsesSmallestThatHolds30() {
        #expect(CapturePolicy.choose(formats, tier: .survival) == F(width: 1280, height: 720, fps: 60))
    }

    @Test func detectorSlowsDownAsItHeats() {
        #expect(CapturePolicy.detectInterval(.max) < CapturePolicy.detectInterval(.sustained))
        #expect(CapturePolicy.detectInterval(.sustained) < CapturePolicy.detectInterval(.survival))
        #expect(CapturePolicy.Tier(.serious) == .sustained)
        #expect(CapturePolicy.Tier(.critical) == .survival)
    }
}
