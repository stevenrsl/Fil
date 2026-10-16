import Foundation
import UniformTypeIdentifiers

/// Glisser depuis Fil vers le Finder (ou une autre application) : une promesse de fichier.
/// Rien n'est téléchargé avant le dépôt ; ensuite, le téléchargement passe par la file des transferts,
/// visible et annulable dans le plateau, puis le fichier est remis à l'application qui l'a reçu.
extension BrowserModel {
    func dragItem(for file: RemoteFile) -> NSItemProvider? {
        // Lien de cible inconnue : on ne sait pas promettre un fichier ou un dossier.
        guard file.kind != .link else { return nil }
        let type: UTType = file.isDirectory ? .folder : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
        let item = NSItemProvider()
        item.suggestedName = file.name
        item.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
            let progress = Progress(totalUnitCount: max(file.byteCount ?? 1, 1))
            let reply = PromiseReply(completion)
            Task { @MainActor in
                guard let self else { return reply(.failure(CancellationError())) }
                self.deliver(file, progress: progress, reply: reply)
            }
            return progress
        }
        return item
    }

    private func deliver(_ file: RemoteFile, progress: Progress, reply: PromiseReply) {
        let folder: URL
        do {
            folder = try DragCache.makeFolder()
        } catch {
            return reply(.failure(error))
        }
        let id = transfers.download(file, via: provider, into: folder) { result in
            if case .success = result { progress.completedUnitCount = progress.totalUnitCount }
            reply(result)
        }
        // Annuler depuis le Finder annule le transfert ; l'inverse passe par la promesse.
        let transfers = transfers
        progress.cancellationHandler = { Task { @MainActor in transfers.cancel(id) } }
    }
}

/// Le rappel de `NSItemProvider` n'est pas marqué `Sendable`, mais il est fait pour être appelé
/// depuis n'importe quel fil, une seule fois.
private struct PromiseReply: @unchecked Sendable {
    private let completion: (URL?, Bool, Error?) -> Void

    init(_ completion: @escaping (URL?, Bool, Error?) -> Void) {
        self.completion = completion
    }

    func callAsFunction(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): completion(url, false, nil)
        case .failure(let error): completion(nil, false, error)
        }
    }
}

/// Copies remises par glisser-déposer. Reconstructible : l'application qui les reçoit en fait sa
/// propre copie, et ce qui a plus d'un jour est effacé au lancement.
enum DragCache {
    static let staleAfter: TimeInterval = 24 * 3600

    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Fil/Drags", isDirectory: true)
    }

    /// Un dossier par dépôt : deux fichiers de même nom ne se marchent pas dessus.
    static func makeFolder(in root: URL = root) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Un fichier de Fil revenu dans Fil (déposé sur sa propre liste) ne doit pas repartir au serveur.
    static func contains(_ url: URL, root: URL = root) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    static func purgeStale(in root: URL = root, now: Date = .now) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if now.timeIntervalSince(modified) > staleAfter {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
