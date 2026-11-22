import Foundation
import os

/// Une couleur en clair et en sombre, en sRGB 0xRRGGBB.
struct Shade: Sendable, Equatable {
    let light: UInt32
    let dark: UInt32
    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }
}

/// Tous les jetons de couleur d'un mode : la seule source des couleurs de Fil.
/// Ajouter un jeton ici oblige à le donner à chaque mode ; `ThemeContrastTests` vérifie les paires lisibles.
struct PaletteSet: Sendable {
    let ground, groundSunk, surface: Shade
    let ink, inkSoft, inkFaint, hairline: Shade
    let accent, onAccent, accentWash, accentInk: Shade
    let alert, alertWash, caution: Shade
    /// Transfert terminé. Séparé de `accentInk` : un accent n'est pas toujours une couleur de succès.
    let success: Shade
    /// Barre de progression : tient 3:1 contre son rail (`hairline`).
    let progress: Shade
    /// Fond de la ligne choisie dans la liste des fichiers, à la place de l'accent de macOS.
    let selection: Shade
}

/// Un jeton de `PaletteSet`, lisible depuis un fournisseur de couleur hors du fil principal.
typealias PaletteToken = KeyPath<PaletteSet, Shade> & Sendable

extension ThemeID {
    var palette: PaletteSet {
        switch self {
        case .defaut: .defaut
        case .veilleuse: .veilleuse
        case .net: .net
        }
    }
}

extension PaletteSet {
    /// Le bleu pastel du 2026-10-09.
    static let defaut = PaletteSet(
        ground: Shade(0xEBF0F7, 0x121A26), groundSunk: Shade(0xDBE6F2, 0x0D141F), surface: Shade(0xFAFCFF, 0x1C2636),
        ink: Shade(0x1C2636, 0xEBF2FF), inkSoft: Shade(0x54637A, 0xBAC7DE), inkFaint: Shade(0x6E7D96, 0x9EB0C9),
        hairline: Shade(0xC7D4E8, 0x334561),
        accent: Shade(0xABC9F0, 0x82ADE6), onAccent: Shade(0x1A335C, 0x12213D),
        accentWash: Shade(0xD9E8FA, 0x263854), accentInk: Shade(0x3866B2, 0x9CCCFF),
        alert: Shade(0x99453B, 0xED9485), alertWash: Shade(0xF7E8E3, 0x3D2121), caution: Shade(0x8C6B29, 0xE6C273),
        success: Shade(0x3866B2, 0x9CCCFF), progress: Shade(0x3866B2, 0x9CCCFF), selection: Shade(0xD9E8FA, 0x263854)
    )

    /// Pour 3 h du matin au sens propre : peu de bleu, ambre bas, noir chaud.
    static let veilleuse = PaletteSet(
        ground: Shade(0xF4EEE3, 0x15110C), groundSunk: Shade(0xEAE1D1, 0x0F0C08), surface: Shade(0xFBF8F2, 0x1E1912),
        ink: Shade(0x2A2118, 0xEDE2D0), inkSoft: Shade(0x5C4E3E, 0xC4B59D), inkFaint: Shade(0x6F604C, 0xA69680),
        hairline: Shade(0xDDD2BF, 0x3A3125),
        accent: Shade(0xB87A1E, 0xD9A04A), onAccent: Shade(0x1F1405, 0x24170A),
        accentWash: Shade(0xF5E4C3, 0x3A2A14), accentInk: Shade(0x87560F, 0xE8B866),
        alert: Shade(0x9B3B2A, 0xE8907E), alertWash: Shade(0xF6E0D8, 0x3A1C16), caution: Shade(0x6A621A, 0xC9C06A),
        success: Shade(0x4A6627, 0xA9C27F), progress: Shade(0x98600F, 0xD9A04A), selection: Shade(0xF0DDB6, 0x3E2F18)
    )

    /// Contraste élevé : noir, blanc, un bleu franc.
    static let net = PaletteSet(
        ground: Shade(0xFFFFFF, 0x000000), groundSunk: Shade(0xF0F0F0, 0x0D0D0D), surface: Shade(0xFFFFFF, 0x0A0A0A),
        ink: Shade(0x000000, 0xFFFFFF), inkSoft: Shade(0x262626, 0xE0E0E0), inkFaint: Shade(0x404040, 0xC2C2C2),
        hairline: Shade(0xA0A0A0, 0x5A5A5A),
        accent: Shade(0x0040B0, 0x8DB8FF), onAccent: Shade(0xFFFFFF, 0x000000),
        accentWash: Shade(0xDCE6FA, 0x10264D), accentInk: Shade(0x0036A0, 0xA8C8FF),
        alert: Shade(0x990000, 0xFF8A80), alertWash: Shade(0xFDE3E3, 0x3D0A0A), caution: Shade(0x6B4A00, 0xFFD36B),
        success: Shade(0x00632A, 0x7FE0A0), progress: Shade(0x0040B0, 0x8DB8FF), selection: Shade(0xC9D8F7, 0x1F3A6B)
    )
}

/// Le mode lu au moment du dessin. Écrit par `AppModel`, lu par les fournisseurs de couleur de `Palette`,
/// qu'AppKit peut appeler hors du fil principal.
enum ThemeSelection {
    private static let lock = OSAllocatedUnfairLock(initialState: ThemeID.defaut)
    static var current: ThemeID {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
