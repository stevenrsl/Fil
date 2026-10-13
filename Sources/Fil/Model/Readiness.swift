import Foundation

/// Conditions bloquantes, chacune avec une phrase lisible.
public struct Readiness: Equatable, Sendable {
    public let reasons: [String]
    public var isReady: Bool { reasons.isEmpty }
    public var reason: String? { reasons.first }

    public init(reasons: [String] = []) { self.reasons = reasons }

    /// Ce qui empêche de lancer la connexion, dans l'ordre où l'utilisateur doit le régler.
    public static func connecting(_ connection: RemoteConnection?) -> Readiness {
        guard let connection else {
            return Readiness(reasons: ["Choisis une connexion pour continuer."])
        }
        var reasons: [String] = []
        if let unavailable = connection.protocol.unavailableReason {
            reasons.append(unavailable)
        }
        let host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty {
            reasons.append(connection.protocol == .kdrive
                ? "Ajoute l'identifiant de ton kDrive ou son adresse WebDAV."
                : "Ajoute l'adresse du serveur.")
        } else if host.contains(where: \.isWhitespace) {
            reasons.append("L'adresse du serveur ne doit pas contenir d'espace.")
        }
        if !(1...65_535).contains(connection.port) {
            reasons.append("Le port doit être compris entre 1 et \(Format.count(65_535)).")
        }
        if connection.protocol == .kdrive, connection.username.trimmingCharacters(in: .whitespaces).isEmpty {
            reasons.append("Ajoute l'adresse e-mail de ton compte Infomaniak.")
        }
        return Readiness(reasons: reasons)
    }
}
