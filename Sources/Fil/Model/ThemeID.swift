import Foundation

/// Un mode graphique, choisi dans les réglages. Le nom brut est ce qui est enregistré : ne jamais le renommer.
/// Les couleurs de chaque mode vivent dans `Design/Theme.swift`.
enum ThemeID: String, CaseIterable, Sendable {
    case defaut, veilleuse, net

    var label: String {
        switch self {
        case .defaut: "Défaut"
        case .veilleuse: "Veilleuse"
        case .net: "Net"
        }
    }

    /// Une phrase pour dire à quoi sert le mode, sous son nom.
    var summary: String {
        switch self {
        case .defaut: "Ciel pâle, bleu poudre."
        case .veilleuse: "Ambre de nuit, peu de bleu."
        case .net: "Contraste élevé, texte au-delà de 7:1."
        }
    }
}
