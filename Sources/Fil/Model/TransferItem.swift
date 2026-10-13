import Foundation

/// Un transfert tel que l'utilisateur l'a lancé : un fichier ou un dossier entier.
public struct TransferItem: Identifiable, Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case download, upload }

    public enum State: Equatable, Sendable {
        case waiting
        /// Inventaire d'un dossier avant de copier quoi que ce soit.
        case preparing
        case running
        case done
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public let direction: Direction
    public let name: String
    public let isFolder: Bool
    public let connectionName: String
    /// Source d'un téléchargement, destination d'un envoi.
    public let remotePath: RemotePath
    /// Source d'un envoi ; destination d'un téléchargement (le dossier, puis le fichier final).
    public var localURL: URL
    public var state: State
    public var totalBytes: Int64?
    public var transferredBytes: Int64
    public var fileCount: Int?
    public var completedFiles: Int
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: UUID = UUID(), direction: Direction, name: String, isFolder: Bool, connectionName: String, remotePath: RemotePath, localURL: URL, totalBytes: Int64? = nil) {
        self.id = id
        self.direction = direction
        self.name = name
        self.isFolder = isFolder
        self.connectionName = connectionName
        self.remotePath = remotePath
        self.localURL = localURL
        self.state = .waiting
        self.totalBytes = totalBytes
        self.transferredBytes = 0
        self.fileCount = nil
        self.completedFiles = 0
    }

    public var isActive: Bool {
        switch state {
        case .waiting, .preparing, .running: true
        case .done, .failed, .cancelled: false
        }
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    /// Débit moyen depuis le début, en octets par seconde.
    public func rate(now: Date) -> Double? {
        guard let startedAt, state == .running else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 1, transferredBytes > 0 else { return nil }
        return Double(transferredBytes) / elapsed
    }

    public func remaining(now: Date) -> TimeInterval? {
        guard let rate = rate(now: now), rate > 0, let totalBytes, totalBytes > transferredBytes else { return nil }
        return Double(totalBytes - transferredBytes) / rate
    }

    /// Phrase d'état : chaque attente dit ce qu'elle attend.
    public func phrase(now: Date) -> String {
        switch state {
        case .waiting:
            return "En attente d'une place libre"
        case .preparing:
            if let fileCount { return "Inventaire · \(Format.files(fileCount)) trouvés" }
            return direction == .download ? "Inventaire du dossier distant…" : "Inventaire du dossier…"
        case .running:
            var parts: [String] = []
            if isFolder, let fileCount {
                parts.append("\(Format.count(min(completedFiles + 1, fileCount))) sur \(Format.files(fileCount))")
            }
            if let totalBytes, totalBytes > 0 {
                parts.append(Format.progress(transferredBytes, of: totalBytes))
            } else if transferredBytes > 0 {
                parts.append(Format.bytes(transferredBytes))
            } else {
                parts.append(direction == .download ? "Ouverture du fichier distant…" : "Ouverture du fichier…")
            }
            if let rate = rate(now: now) { parts.append(Format.rate(rate)) }
            if let remaining = remaining(now: now) { parts.append("encore \(Format.duration(remaining))") }
            return parts.joined(separator: " · ")
        case .done:
            let size = totalBytes.map { " · \(Format.bytes($0))" } ?? ""
            switch direction {
            case .download:
                let folder = FileManager.default.displayName(atPath: localURL.deletingLastPathComponent().path)
                return "Téléchargé dans « \(folder) »\(size)"
            case .upload: return "Envoyé dans « \(remotePath.parent?.name ?? "/") »\(size)"
            }
        case .failed(let reason):
            return reason
        case .cancelled:
            return "Annulé"
        }
    }
}
