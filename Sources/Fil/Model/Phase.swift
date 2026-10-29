import Foundation

/// Une phase = une page. Les transferts ne sont pas une phase : ils vivent à côté, dans le plateau.
public enum Phase: Equatable, Sendable {
    /// Choisir ou régler une connexion.
    case choosing
    case connecting(RemoteConnection)
    case browsing(RemoteConnection)
    /// Une première rencontre à vérifier : l'empreinte d'un serveur SSH, ou un certificat que macOS ne reconnaît pas.
    case confirming(RemoteConnection, TrustRequest)
    /// La page de réglage, avec la raison de l'échec au-dessus du bouton.
    case failed(RemoteConnection, reason: String)

    public var connection: RemoteConnection? {
        switch self {
        case .choosing: nil
        case .connecting(let connection), .browsing(let connection), .confirming(let connection, _), .failed(let connection, _): connection
        }
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Ce que la page de confiance demande de vérifier, quand c'est la phase en cours.
    public var confirmation: TrustRequest? {
        if case .confirming(_, let request) = self { return request }
        return nil
    }

    public var isConfirming: Bool {
        if case .confirming = self { return true }
        return false
    }

    public var isBrowsing: Bool {
        if case .browsing = self { return true }
        return false
    }
}
