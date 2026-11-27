import Foundation

/// Un mode graphique, choisi dans les réglages. Le nom brut est ce qui est enregistré : ne jamais le renommer.
/// Les couleurs de chaque mode vivent dans `Design/Theme.swift`.
enum ThemeID: String, CaseIterable, Sendable {
    case defaut, veilleuse, ardoise, lin, mousse, prune, net

    var label: String {
        switch self {
        case .defaut: "Défaut"
        case .veilleuse: "Veilleuse"
        case .ardoise: "Ardoise"
        case .lin: "Lin"
        case .mousse: "Mousse"
        case .prune: "Prune"
        case .net: "Net"
        }
    }

    /// Une phrase pour dire à quoi sert le mode, sous son nom.
    var summary: String {
        switch self {
        case .defaut: "Ciel pâle, bleu poudre."
        case .veilleuse: "Ambre de nuit, peu de bleu."
        case .ardoise: "Graphite presque monochrome."
        case .lin: "Papier écru, terre cuite."
        case .mousse: "Sauge et vert sous-bois."
        case .prune: "Aubergine, gris lavés de prune."
        case .net: "Contraste élevé, texte au-delà de 7:1."
        }
    }
}
