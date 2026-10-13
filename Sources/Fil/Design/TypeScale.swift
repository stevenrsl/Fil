import SwiftUI

/// Échelle typographique : serif pour les titres, système pour le travail, chasse fixe pour les chiffres.
enum TypeScale {
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
}
