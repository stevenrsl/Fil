import SwiftUI

/// Échelle typographique : serif pour les titres, système pour le travail, chasse fixe pour les chiffres.
/// Sur iOS, les mêmes rôles suivent les styles de texte du système, et donc la taille choisie dans les réglages.
enum TypeScale {
    #if os(iOS)
    static let display = Font.system(.largeTitle, design: .serif)
    static let lede = Font.system(.title3, design: .serif).italic()
    static let section = Font.system(.title3, design: .serif)
    static let body = Font.body
    static let bodyStrong = Font.body.weight(.medium)
    static let label = Font.subheadline
    static let caption = Font.caption
    static let figures = Font.system(.footnote, design: .monospaced)
    static let button = Font.body.weight(.semibold)
    static let badge = Font.system(.caption2, design: .rounded).weight(.bold)
    #else
    static let display = Font.system(size: 30, design: .serif)
    static let lede = Font.system(size: 16, design: .serif).italic()
    static let section = Font.system(size: 18, design: .serif)
    static let body = Font.system(size: 13.5)
    static let bodyStrong = Font.system(size: 13.5, weight: .medium)
    static let label = Font.system(size: 12.5)
    static let caption = Font.system(size: 11.5)
    static let figures = Font.system(size: 12, design: .monospaced)
    static let button = Font.system(size: 14, weight: .medium)
    static let badge = Font.system(size: 11, weight: .bold, design: .rounded)
    #endif
}
