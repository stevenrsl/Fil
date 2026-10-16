import Foundation

/// Un fichier distant ouvert pour modification : copie locale, éditeur, et envoi à chaque enregistrement.
public struct EditSession: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case downloading
        /// Ouvert chez l'utilisateur ; ce qui est enregistré a été envoyé.
        case editing
        case uploading
        /// Le serveur a bougé de son côté : rien n'est envoyé sans l'accord de l'utilisateur.
        case conflict(String)
        case failed(String)
    }

    public let id: UUID
    public let connectionID: UUID
    public let connectionName: String
    public let remotePath: RemotePath
    public let localURL: URL
    public var state: State
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64?
    /// Dernier enregistrement arrivé sur le serveur.
    public var syncedAt: Date?

    public init(id: UUID = UUID(), connectionID: UUID, connectionName: String, remotePath: RemotePath, localURL: URL, state: State = .downloading, totalBytes: Int64? = nil) {
        self.id = id
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.remotePath = remotePath
        self.localURL = localURL
        self.state = state
        self.totalBytes = totalBytes
    }

    public var name: String { remotePath.name }

    /// Des modifications attendent l'utilisateur (ou le réseau) : fermer Fil les laisserait de côté.
    public var needsAttention: Bool {
        switch state {
        case .conflict, .failed: true
        default: false
        }
    }

    /// Phrase d'état : chaque attente dit ce qu'elle attend.
    public func phrase() -> String {
        switch state {
        case .downloading:
            if let totalBytes, totalBytes > 0, downloadedBytes > 0 {
                return "Téléchargement de « \(name) » · \(Format.progress(downloadedBytes, of: totalBytes))"
            }
            return "Téléchargement de « \(name) »…"
        case .editing:
            guard let syncedAt else { return "Ouvert dans ton éditeur : chaque enregistrement est envoyé au serveur." }
            return "Dernier enregistrement envoyé à \(Format.time(syncedAt))."
        case .uploading:
            return "Envoi des modifications…"
        case .conflict(let reason):
            return "\(reason) Écraser la version du serveur, ou abandonner tes changements."
        case .failed(let reason):
            return "\(reason) Ta copie est conservée."
        }
    }
}
