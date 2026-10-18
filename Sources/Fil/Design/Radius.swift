import CoreGraphics

enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 14
}

enum Spacing {
    static let hair: CGFloat = 4
    static let tight: CGFloat = 8
    static let regular: CGFloat = 14
    static let loose: CGFloat = 22
    #if os(iOS)
    static let page: CGFloat = 20
    /// Hauteur minimale d'un bouton : la cible tactile recommandée par Apple.
    static let control: CGFloat = 44
    #else
    static let page: CGFloat = 30
    static let control: CGFloat = 36
    #endif
    static let pageWidth: CGFloat = 812
    static let sidebarWidth: CGFloat = 210
}
