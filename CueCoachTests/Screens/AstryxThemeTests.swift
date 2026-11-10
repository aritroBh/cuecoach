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
            ("legal", AX.legal, l.dataShamrock5, d.dataShamrock3),
            ("caution", AX.caution, l.textWarning, d.warning),
            ("warn", AX.warn, l.dataOrange4, d.dataCategoricalOrange),
            ("danger", AX.danger, l.dataRed4, d.dataRed3),
            ("brilliant", AX.brilliant, l.dataCategoricalCyan, d.iconCyan),
            ("teamA", AX.teamA, l.accent, d.textAccent),
            ("teamB", AX.teamB, l.dataOrange4, d.dataCategoricalOrange),
            ("teamBText", AX.teamBText, l.dataOrange5, d.dataCategoricalOrange),
        ]
    }()

    @Test(arguments: roles.indices)
    func appRolesAreAstryxTokensInBothModes(_ i: Int) {
        let (name, role, light, dark) = Self.roles[i]
        #expect(Self.same(role, light, Self.light), "\(name) light")
        #expect(Self.same(role, dark, Self.dark), "\(name) dark")
    }

    // MARK: WCAG contrast (Grok 4.7 review MAJOR)

    private static func luminance(_ c: Color, _ traits: UITraitCollection) -> Double {
        let v = rgba(c, traits)
        func lin(_ x: CGFloat) -> Double { let x = Double(x); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(v[0]) + 0.7152 * lin(v[1]) + 0.0722 * lin(v[2])
    }

    static func contrast(_ a: Color, _ b: Color, _ traits: UITraitCollection) -> Double {
        let (x, y) = (luminance(a, traits), luminance(b, traits))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Roles drawn as words: at least 4.5:1 on the page and on a card, light and dark.
    static let textRoles: [(String, Color)] = [
        ("ink", AX.ink), ("inkMuted", AX.inkMuted), ("accentText", AX.accentText), ("legal", AX.legal),
        ("caution", AX.caution), ("danger", AX.danger), ("teamA", AX.teamA), ("teamBText", AX.teamBText),
    ]
    /// Roles drawn as rings, glyphs and strokes: at least 3:1 (WCAG non-text contrast).
    static let ringRoles: [(String, Color)] = [
        ("accent", AX.accent), ("warn", AX.warn), ("teamB", AX.teamB), ("brilliant", AX.brilliant),
    ] + textRoles

    @Test func textAndRingRolesMeetWCAGOnPageAndCardInBothModes() {
        var failures: [String] = []
        for (traits, mode) in [(Self.light, "light"), (Self.dark, "dark")] {
            for (ground, groundName) in [(AX.page, "page"), (AX.surface, "card")] {
                for (name, role) in Self.textRoles where Self.contrast(role, ground, traits) < 4.5 {
                    failures.append("text \(name) on \(groundName) \(mode): \(Self.contrast(role, ground, traits))")
                }
                for (name, role) in Self.ringRoles where Self.contrast(role, ground, traits) < 3 {
                    failures.append("ring \(name) on \(groundName) \(mode): \(Self.contrast(role, ground, traits))")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The review card's ball glyph outline is what separates the white cue ball from a white light-mode card:
    /// opaque and at least 3:1 (non-text contrast) on the page and the card, light and dark.
    @Test func reviewBallOutlineSeparatesTheCueBallFromTheCard() {
        var failures: [String] = []
        for (traits, mode) in [(Self.light, "light"), (Self.dark, "dark")] {
            if Self.rgba(ReviewBallGlyph.outline, traits)[3] < 1 { failures.append("outline translucent \(mode)") }
            for (ground, groundName) in [(AX.page, "page"), (AX.surface, "card")]
            where Self.contrast(ReviewBallGlyph.outline, ground, traits) < 3 {
                failures.append("outline on \(groundName) \(mode): \(Self.contrast(ReviewBallGlyph.outline, ground, traits))")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Team B (ring and words) stays clearly apart from Team A blue and from caution amber: CIE76 colour
    /// difference at least 20 in both modes (lightness counts, not only hue).
    @Test func teamBIsDistinctFromTeamAAndCaution() {
        func lab(_ c: Color, _ t: UITraitCollection) -> (Double, Double, Double) {
            let v = Self.rgba(c, t)
            func lin(_ x: CGFloat) -> Double { let x = Double(x); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            let (r, g, b) = (lin(v[0]), lin(v[1]), lin(v[2]))
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        func deltaE(_ a: Color, _ b: Color, _ t: UITraitCollection) -> Double {
            let (p, q) = (lab(a, t), lab(b, t))
            return ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
        }
        for t in [Self.light, Self.dark] {
            for b in [AX.teamB, AX.teamBText] {
                for other in [AX.teamA, AX.caution] { #expect(deltaE(b, other, t) >= 20) }
            }
        }
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
