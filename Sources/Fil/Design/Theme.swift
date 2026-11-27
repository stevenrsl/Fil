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
        case .ardoise: .ardoise
        case .lin: .lin
        case .mousse: .mousse
        case .prune: .prune
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

    /// Presque monochrome : gris, encre, un bouton principal noir sur blanc (blanc sur noir la nuit).
    static let ardoise = PaletteSet(
        ground: Shade(0xEFEFEE, 0x141516), groundSunk: Shade(0xE4E4E2, 0x0E0F10), surface: Shade(0xFAFAF9, 0x1C1D1F),
        ink: Shade(0x1B1C1E, 0xECECEA), inkSoft: Shade(0x4A4C50, 0xB9BABD), inkFaint: Shade(0x5F6267, 0x9A9CA0), hairline: Shade(0xD3D4D6, 0x303235),
        accent: Shade(0x2B2D31, 0xE4E4E1), onAccent: Shade(0xF5F5F4, 0x1A1B1D), accentWash: Shade(0xE2E3E5, 0x2C2E31), accentInk: Shade(0x2B2D31, 0xE4E4E1),
        alert: Shade(0xA3322A, 0xF08C80), alertWash: Shade(0xF5E2DF, 0x3A1D1A), caution: Shade(0x7A5A10, 0xE3C27A),
        success: Shade(0x2F6B3E, 0x8CCB98), progress: Shade(0x3C3F44, 0xD4D5D2), selection: Shade(0xDCDDE0, 0x34373B)
    )

    /// Un carnet : papier écru, encre sépia, accent terre cuite ; l'erreur passe au lie-de-vin.
    static let lin = PaletteSet(
        ground: Shade(0xF3EEE6, 0x1A1613), groundSunk: Shade(0xE9E2D6, 0x13100D), surface: Shade(0xFCFAF6, 0x231E1A),
        ink: Shade(0x2B241E, 0xEFE6DC), inkSoft: Shade(0x5C5047, 0xC7B9AA), inkFaint: Shade(0x6E6157, 0xA89A8B), hairline: Shade(0xDCD2C4, 0x3B332C),
        accent: Shade(0xA9522E, 0xE08A62), onAccent: Shade(0xFFF8F2, 0x2A140A), accentWash: Shade(0xF3DDD0, 0x3E261B), accentInk: Shade(0x94421F, 0xEFA07C),
        alert: Shade(0x962638, 0xF08A98), alertWash: Shade(0xF6DFE2, 0x3C1A20), caution: Shade(0x735810, 0xE1C27A),
        success: Shade(0x476530, 0xA8C98C), progress: Shade(0xA9522E, 0xE08A62), selection: Shade(0xF0DCCD, 0x43291D)
    )

    /// Sous-bois : sauge, vert profond, ombre végétale.
    static let mousse = PaletteSet(
        ground: Shade(0xEAF0EA, 0x0E1511), groundSunk: Shade(0xDEE7DF, 0x0A100C), surface: Shade(0xF8FBF8, 0x151F19),
        ink: Shade(0x17241C, 0xE3EEE6), inkSoft: Shade(0x435448, 0xB2C4B7), inkFaint: Shade(0x55685B, 0x93A898), hairline: Shade(0xCBD9CE, 0x26362C),
        accent: Shade(0x3B7350, 0x7FBF94), onAccent: Shade(0xF4FBF6, 0x0D2016), accentWash: Shade(0xD6E8DA, 0x1D3326), accentInk: Shade(0x2E6644, 0x92D3A7),
        alert: Shade(0xA3392E, 0xEE8F84), alertWash: Shade(0xF5E1DD, 0x3A1B18), caution: Shade(0x765A10, 0xE2C47C),
        success: Shade(0x2A6237, 0x92D3A7), progress: Shade(0x3B7350, 0x7FBF94), selection: Shade(0xD3E6D8, 0x21392B)
    )

    /// Aubergine : un violet sourd, des gris lavés de prune.
    static let prune = PaletteSet(
        ground: Shade(0xF1EDF2, 0x17121A), groundSunk: Shade(0xE6E0E9, 0x110D13), surface: Shade(0xFBF9FC, 0x201A24),
        ink: Shade(0x241B29, 0xEEE6F1), inkSoft: Shade(0x54465B, 0xC5B6CC), inkFaint: Shade(0x66586E, 0xA797AF), hairline: Shade(0xD8CEDD, 0x382E3E),
        accent: Shade(0x6B3F7E, 0xC59ADB), onAccent: Shade(0xFAF5FC, 0x241330), accentWash: Shade(0xE9DDEE, 0x352641), accentInk: Shade(0x6B3F7E, 0xD4AEE6),
        alert: Shade(0xA3302F, 0xF08C86), alertWash: Shade(0xF5E0DF, 0x3B1B1C), caution: Shade(0x765810, 0xE3C47A),
        success: Shade(0x2F6A47, 0x8DD0A6), progress: Shade(0x7D4C91, 0xC59ADB), selection: Shade(0xE5D7EC, 0x3C2B48)
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
