#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Les couleurs lues par les vues. Chacune suit l'apparence (clair, sombre) et le mode choisi
/// (`ThemeSelection`) au moment du dessin ; les valeurs viennent de `PaletteSet`, jamais d'ici.
enum Palette {
    static let ground = themed(\.ground)
    static let groundSunk = themed(\.groundSunk)
    static let surface = themed(\.surface)
    static let ink = themed(\.ink)
    static let inkSoft = themed(\.inkSoft)
    static let inkFaint = themed(\.inkFaint)
    static let hairline = themed(\.hairline)
    static let accent = themed(\.accent)
    static let accentWash = themed(\.accentWash)
    static let onAccent = themed(\.onAccent)
    static let accentInk = themed(\.accentInk)
    static let alert = themed(\.alert)
    static let alertWash = themed(\.alertWash)
    /// Pour le seul avertissement « non chiffré » : ni alarme, ni accent.
    static let caution = themed(\.caution)
    static let success = themed(\.success)
    static let progress = themed(\.progress)
    static let selection = themed(\.selection)
    /// Fond de l'aperçu photo, et son texte : noir dans les deux apparences et dans tous les modes.
    static let darkroom = Color.black
    static let onDarkroom = Color.white

    /// Une couleur fixée à un mode, qui suit seulement l'apparence : pour montrer un mode qui n'est pas le courant.
    static func preview(_ token: PaletteToken, of theme: ThemeID) -> Color {
        color { theme.palette[keyPath: token] }
    }

    #if os(macOS)
    /// La même couleur pour AppKit (tableau des fichiers).
    static func nsColor(_ token: PaletteToken) -> NSColor {
        dynamicNSColor { ThemeSelection.current.palette[keyPath: token] }
    }
    #endif

    private static func themed(_ token: PaletteToken) -> Color {
        color { ThemeSelection.current.palette[keyPath: token] }
    }

    private static func color(_ shade: @escaping @Sendable () -> Shade) -> Color {
        #if os(macOS)
        Color(nsColor: dynamicNSColor(shade))
        #else
        Color(uiColor: UIColor { traits in
            let value = shade()
            return UIColor(srgb: traits.userInterfaceStyle == .dark ? value.dark : value.light)
        })
        #endif
    }

    #if os(macOS)
    private static func dynamicNSColor(_ shade: @escaping @Sendable () -> Shade) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = shade()
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgb: isDark ? value.dark : value.light)
        }
    }
    #endif
}

#if os(macOS)
extension NSColor {
    convenience init(srgb hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension UIColor {
    convenience init(srgb hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
