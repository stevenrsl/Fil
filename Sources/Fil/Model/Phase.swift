import Foundation

/// Une phase = une page. Les transferts ne sont pas une phase : ils vivent à côté, dans le plateau.
public enum Phase: Equatable, Sendable {
    /// Choisir ou régler une connexion.
    case choosing
    case connecting(RemoteConnection)
    case browsing(RemoteConnection)
    /// La page de réglage, avec la raison de l'échec au-dessus du bouton.
    case failed(RemoteConnection, reason: String)

    public var connection: RemoteConnection? {
        switch self {
        case .choosing: nil
        case .connecting(let connection), .browsing(let connection), .failed(let connection, _): connection
        }
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var isBrowsing: Bool {
        if case .browsing = self { return true }
        return false
    }
}
