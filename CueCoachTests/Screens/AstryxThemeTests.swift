import Foundation
import SwiftUI
import Testing
import UIKit
import Astryx
@testable import CueCoach

/// D34: every screen and overlay paints with Meta's Astryx Default theme, light and dark.
@Suite("Astryx theme (D34)")
struct AstryxThemeTests {
    private static let light = UITraitCollection(userInterfaceStyle: .light)
    private static let dark = UITraitCollection(userInterfaceStyle: .dark)

    private static func rgba(_ c: Color, _ traits: UITraitCollection) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    private static func same(_ a: Color, _ b: Color, _ traits: UITraitCollection) -> Bool {
        zip(rgba(a, traits), rgba(b, traits)).allSatisfy { abs($0 - $1) < 0.003 }
    }

    /// (app role, light token, dark token)
    static let roles: [(String, Color, Color, Color)] = {
        let l = Theme.default.light.color, d = Theme.default.dark.color
        return [
            ("page", AX.page, l.backgroundBody, d.backgroundBody),
            ("surface", AX.surface, l.backgroundCard, d.backgroundCard),
            ("raised", AX.raised, l.backgroundPopover, d.backgroundPopover),
            ("ink", AX.ink, l.textPrimary, d.textPrimary),
            ("inkMuted", AX.inkMuted, l.textSecondary, d.textSecondary),
            ("border", AX.border, l.border, d.border),
            ("accent", AX.accent, l.accent, d.accent),
            ("onAccent", AX.onAccent, l.onAccent, d.onAccent),
            ("legal", AX.legal, l.success, d.dataShamrock3),
            ("caution", AX.caution, l.warning, d.warning),
            ("warn", AX.warn, l.dataCategoricalOrange, d.dataCategoricalOrange),
            ("danger", AX.danger, l.error, d.error),
            ("brilliant", AX.brilliant, l.dataCategoricalCyan, d.iconCyan),
            ("teamA", AX.teamA, l.accent, d.textAccent),
            ("teamB", AX.teamB, l.dataCategoricalOrange, d.dataCategoricalOrange),
        ]
    }()

    @Test(arguments: roles.indices)
    func appRolesAreAstryxTokensInBothModes(_ i: Int) {
        let (name, role, light, dark) = Self.roles[i]
        #expect(Self.same(role, light, Self.light), "\(name) light")
        #expect(Self.same(role, dark, Self.dark), "\(name) dark")
    }

    @Test func pageFollowsTheSystemAppearance() {
        #expect(!Self.same(AX.page, Theme.default.dark.color.backgroundBody, Self.light))
        #expect(Self.same(AX.page, Theme.default.dark.color.backgroundBody, Self.dark))
    }

    /// Overlays sit on the camera feed, which is the same in light and dark, so they always use the
    /// Astryx dark-mode values (bright on a dark, busy ground).
    @Test func liveOverlayPaletteIsTheDarkTokensInEveryMode() {
        let d = Theme.default.dark.color
        let pairs: [(Color, Color)] = [(AXLive.aim, d.onDark), (AXLive.legal, d.dataShamrock3), (AXLive.caution, d.warning),
                                       (AXLive.danger, d.error), (AXLive.brilliant, d.iconCyan), (AXLive.scrim, d.overlay),
                                       (AXLive.chip, d.backgroundPopover)]
        for (role, token) in pairs {
            #expect(Self.same(role, token, Self.light))
            #expect(Self.same(role, token, Self.dark))
        }
    }

    @Test func ratingTonesUseTheAstryxRoles() {
        #expect(Self.same(BadgeTone.brilliant.color, AX.brilliant, Self.dark))
        #expect(Self.same(BadgeTone.legal.color, AX.legal, Self.light))
        #expect(Self.same(BadgeTone.caution.color, AX.caution, Self.dark))
        #expect(Self.same(BadgeTone.warn.color, AX.warn, Self.dark))
        #expect(Self.same(BadgeTone.danger.color, AX.danger, Self.light))
        #expect(Self.same(BadgeTone.ink.color, AX.ink, Self.light))
    }

    @Test func avatarSwatchesAreAstryxCategoricalColors() {
        let l = Theme.default.light.color
        let expected: [String: Color] = ["blue": l.dataCategoricalBlue, "teal": l.dataCategoricalTeal,
                                         "green": l.dataCategoricalGreen, "yellow": l.dataYellow3,
                                         "orange": l.dataCategoricalOrange, "red": l.dataCategoricalRed,
                                         "pink": l.dataCategoricalPink, "purple": l.dataCategoricalPurple]
        #expect(Set(AX.avatarNames) == Set(expected.keys))
        for (name, token) in expected { #expect(Self.same(AX.avatar(name), token, Self.light), "\(name)") }
    }

    /// Profiles saved before D34 store a hex colour; it maps to the Astryx swatch nearest in hue.
    @Test func legacyHexAvatarColorsMapToTheNearestAstryxSwatch() {
        #expect(AX.avatarName(forHex: "#60A5FA") == "blue")
        #expect(AX.avatarName(forHex: "#A78BFA") == "purple")
        #expect(AX.avatarName(forHex: "#14B8A6") == "teal")
        #expect(AX.avatarName(forHex: "not a colour") == nil)
        #expect(Self.same(AX.avatar("#60A5FA"), AX.avatar("blue"), Self.light))
    }

    @Test func typeScaleComesFromAstryxTokens() {
        let f = Theme.default.light.font
        #expect(AXType.display.size(f) == f.display2.size)
        #expect(AXType.title.size(f) == f.heading1.size)
        #expect(AXType.subtitle.size(f) == f.heading2.size)
        #expect(AXType.headline.size(f) == f.large.size)
        #expect(AXType.body.size(f) == f.size.lg)     // 17 pt body: big and calm, not Astryx's 14 pt web body
        #expect(AXType.label.size(f) == f.label.size)
    }

    /// AX5 (Astryx text scale 3.1): body grows fully, titles grow less, as iOS's own text styles do.
    @Test func titlesGrowLessThanBodyAtAccessibilitySizes() {
        #expect(AXType.body.scale(3.1, Theme.default.light.font) == 3.1)
        let title = AXType.display.scale(3.1, Theme.default.light.font)
        #expect(title > 1.5 && title < 2.0)
        #expect(AXType.display.scale(1, Theme.default.light.font) == 1)
    }

    /// No ad-hoc colour literals or the old token enums in UI code: every colour is an Astryx token.
    @Test func uiCodeHasNoAdHocColors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("CueCoach")
        let dirs = ["App", "Screens", "Live"]
        let forbidden = try NSRegularExpression(pattern:
            #"Color\(red:|UIColor\(red:|Color\(hex:|saHex|\bSBColor\b|\bSA\.\w|\bColor\.(white|black|red|green|blue|yellow|orange|cyan|gray|pink|purple|teal|mint)\b|[(:,]\s*\.(white|black)\b|\.(white|black)\.opacity|UIColor\.(white|black|red|green|system\w+)"#)
        var hits: [String] = []
        var scanned = 0
        for dir in dirs {
            let e = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            while let url = e?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                // Only files that draw: model/perception logic has no colours.
                guard text.contains("import SwiftUI") || text.contains("import RealityKit") else { continue }
                scanned += 1
                for (n, line) in text.components(separatedBy: .newlines).enumerated() {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") { continue }
                    if forbidden.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        hits.append("\(dir)/\(url.lastPathComponent):\(n + 1): \(t)")
                    }
                }
            }
        }
        #expect(scanned > 15, "scan would be vacuous")
        #expect(hits.isEmpty, "ad-hoc colours:\n\(hits.prefix(60).joined(separator: "\n"))\n(\(hits.count) total)")
    }
}
