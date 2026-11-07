#if DEBUG
import SwiftUI
import Testing
@testable import CueCoach

@Suite struct ScreensADebugRouterTests {
    @Test func dynamicTypeOptions() {
        let base = ["-screen=settings"]
        #expect(ScreensADebugRouter.parse(base)?.typeSize == .large)
        #expect(ScreensADebugRouter.parse(base + ["-dynamicType=xxl"])?.typeSize == .xxLarge)
        #expect(ScreensADebugRouter.parse(base + ["-dynamicType=ax5"])?.typeSize == .accessibility5)
        #expect(ScreensADebugRouter.parse(base + ["-dynamicType=ax5"])?.typeSize.isAccessibilitySize == true)
    }
}
#endif
