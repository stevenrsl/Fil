import Foundation
import UniformTypeIdentifiers

/// Glisser depuis Fil vers le Finder (ou une autre application) : une promesse de fichier AppKit
/// (`NSFilePromiseProvider`, voir `FileTable`). Rien n'est téléchargé avant le dépôt ; ensuite, le
/// téléchargement passe par la file des transferts, visible et annulable dans le plateau, et écrit
/// directement dans le dossier où le fichier a été déposé.
///
/// SwiftUI (`TableRow.itemProvider`, `.draggable`) ne fait pas de vraie promesse sur macOS : il charge
/// le fichier de façon synchrone au début du glisser, sur le fil principal, ce qui gèle Fil.
extension BrowserModel {
    /// Type promis pour `file`, ou `nil` si on ne sait pas dire ce qu'on promet (lien de cible inconnue).
    static func promisedType(for file: RemoteFile) -> UTType? {
        switch file.kind {
        case .link: nil
        case .directory: .folder
        case .file: UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        }
    }

    /// Tient la promesse : télécharge `file` dans le dossier de `destination`, l'URL que propose
    /// l'application qui reçoit. Si ce nom est déjà pris, le fichier arrive sous « nom (2) ».
    @discardableResult
    func deliverPromise(_ file: RemoteFile, to destination: URL, reply: @escaping @MainActor (Error?) -> Void) -> UUID {
        transfers.download(file, via: provider, into: destination.deletingLastPathComponent()) { result in
            switch result {
            case .success: reply(nil)
            case .failure(let error): reply(error)
            }
        }
    }
}

/// Copies remises par les anciennes versions du glisser, qui passaient par le cache. Ce qui a plus
/// d'un jour est effacé au lancement ; un fichier venant de là et redéposé sur Fil n'est pas renvoyé.
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
