import AppKit
import XCTest
@testable import Fil

/// Chaque mode garde ses paires lisibles (WCAG AA) en clair et en sombre.
final class ThemeContrastTests: XCTestCase {
    private struct Pair {
        let text: PaletteToken
        let background: PaletteToken
        let name: String
        /// 4,5 pour du texte, 3 pour un élément graphique.
        let minimum: Double
    }

    private let pairs: [Pair] = [
        Pair(text: \.ink, background: \.ground, name: "ink / ground", minimum: 4.5),
        Pair(text: \.ink, background: \.surface, name: "ink / surface", minimum: 4.5),
        Pair(text: \.ink, background: \.groundSunk, name: "ink / groundSunk", minimum: 4.5),
        Pair(text: \.inkSoft, background: \.ground, name: "inkSoft / ground", minimum: 4.5),
        Pair(text: \.inkSoft, background: \.surface, name: "inkSoft / surface", minimum: 4.5),
        Pair(text: \.inkSoft, background: \.groundSunk, name: "inkSoft / groundSunk", minimum: 4.5),
        Pair(text: \.inkFaint, background: \.surface, name: "inkFaint / surface", minimum: 4.5),
        Pair(text: \.inkFaint, background: \.groundSunk, name: "inkFaint / groundSunk", minimum: 4.5),
        Pair(text: \.accentInk, background: \.surface, name: "accentInk / surface", minimum: 4.5),
        Pair(text: \.accentInk, background: \.groundSunk, name: "accentInk / groundSunk", minimum: 4.5),
        Pair(text: \.onAccent, background: \.accent, name: "onAccent / accent", minimum: 4.5),
        Pair(text: \.accentInk, background: \.accentWash, name: "accentInk / accentWash", minimum: 4.5),
        Pair(text: \.accent, background: \.ground, name: "accent / ground", minimum: 3),
        Pair(text: \.alert, background: \.alertWash, name: "alert / alertWash", minimum: 4.5),
        Pair(text: \.alert, background: \.surface, name: "alert / surface", minimum: 4.5),
        Pair(text: \.caution, background: \.surface, name: "caution / surface", minimum: 4.5),
        Pair(text: \.success, background: \.surface, name: "success / surface", minimum: 4.5),
        Pair(text: \.progress, background: \.surface, name: "progress / surface", minimum: 3),
        Pair(text: \.progress, background: \.hairline, name: "progress / hairline", minimum: 3),
        Pair(text: \.ink, background: \.selection, name: "ink / selection", minimum: 4.5),
        Pair(text: \.accentInk, background: \.selection, name: "accentInk / selection", minimum: 3),
    ]

    /// Écarts connus de Défaut, en clair seulement (voir DECISIONS, 2026-11-22). Un nouvel écart fait échouer le test.
    private let defautLightExceptions: Set<String> = [
        "inkFaint / surface", "inkFaint / groundSunk", "accentInk / groundSunk", "accent / ground",
    ]

    func testEveryThemeMeetsAA() {
        for theme in ThemeID.allCases {
            for pair in pairs {
                for isDark in [false, true] {
                    let ratio = contrast(theme.palette[keyPath: pair.text], theme.palette[keyPath: pair.background], dark: isDark)
                    let excused = theme == .defaut && !isDark && defautLightExceptions.contains(pair.name)
                    if excused {
                        XCTAssertLessThan(ratio, pair.minimum, "\(theme.label) clair, \(pair.name) passe désormais : retirer l'exception")
                    } else {
                        XCTAssertGreaterThanOrEqual(ratio, pair.minimum, "\(theme.label) \(isDark ? "sombre" : "clair"), \(pair.name) : \(ratio)")
                    }
                }
            }
        }
    }

    func testNetKeepsTextAboveSeven() {
        for isDark in [false, true] {
            for text in [\PaletteSet.ink, \.inkSoft, \.inkFaint] {
                for background in [\PaletteSet.ground, \.surface, \.groundSunk] {
                    XCTAssertGreaterThanOrEqual(contrast(PaletteSet.net[keyPath: text], PaletteSet.net[keyPath: background], dark: isDark), 7)
                }
            }
        }
    }

    private func contrast(_ a: Shade, _ b: Shade, dark: Bool) -> Double {
        let la = luminance(dark ? a.dark : a.light), lb = luminance(dark ? b.dark : b.light)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}

/// Le mode choisi est retenu, et les couleurs le suivent au dessin.
@MainActor
final class ThemeSelectionTests: XCTestCase {
    private let suite = "fil.tests.theme"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        ThemeSelection.current = .defaut
    }

    func testPreferenceDefaultsAndUnknownValueFallBack() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.theme, .defaut)
        preferences.theme = .veilleuse
        XCTAssertEqual(Preferences(defaults: defaults).theme, .veilleuse)
        defaults.set("ardoise-retiree", forKey: "fil.theme")
        XCTAssertEqual(preferences.theme, .defaut)
    }

    func testModelPersistsAndAppliesTheTheme() {
        Preferences(defaults: defaults).theme = .net
        let model = AppModel(store: ConnectionStore(defaults: defaults), preferences: Preferences(defaults: defaults), secrets: MemorySecretStore())
        XCTAssertEqual(model.theme, .net)
        XCTAssertEqual(ThemeSelection.current, .net)

        model.theme = .veilleuse
        XCTAssertEqual(ThemeSelection.current, .veilleuse)
        XCTAssertEqual(Preferences(defaults: defaults).theme, .veilleuse)
    }

    func testColorsFollowTheSelectedThemeAndAppearance() {
        let ground = Palette.nsColor(\.ground)
        ThemeSelection.current = .net
        XCTAssertEqual(hex(ground, .aqua), 0xFFFFFF)
        XCTAssertEqual(hex(ground, .darkAqua), 0x000000)
        ThemeSelection.current = .veilleuse
        XCTAssertEqual(hex(ground, .aqua), 0xF4EEE3)
        XCTAssertEqual(hex(ground, .darkAqua), 0x15110C)
    }

    private func hex(_ color: NSColor, _ name: NSAppearance.Name) -> UInt32 {
        var resolved = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)!
        }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return byte(resolved.redComponent) << 16 | byte(resolved.greenComponent) << 8 | byte(resolved.blueComponent)
    }
}
