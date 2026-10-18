import Foundation

/// Un fichier choisi dans l'app Fichiers n'est lisible que le temps d'un accès accordé. Fil le recopie
/// dans son dossier temporaire avant de le confier à la file : l'envoi peut ensuite partir, être repris
/// ou réessayé sans dépendre de cet accès.
enum UploadStaging {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Envois", isDirectory: true)
    }

    /// Copie chaque élément (fichier ou dossier) sous son propre nom, dans un sous-dossier à lui seul :
    /// deux fichiers de même nom venus de dossiers différents ne se marchent pas dessus.
    /// Bloquant : à appeler hors du fil principal.
    static func stage(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let box = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
            let copy = box.appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath)
            // La coordination fait d'abord descendre un fichier iCloud qui n'est pas encore sur l'appareil.
            var coordination: NSError?
            var failure: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
                do {
                    try FileManager.default.copyItem(at: readable, to: copy)
                } catch {
                    failure = error
                }
            }
            if let error = coordination ?? failure { throw error }
            return copy
        }
    }

    /// Au lancement : la file de la session précédente n'existe plus, ses copies ne servent à rien.
    static func purge() {
        try? FileManager.default.removeItem(at: folder)
    }
}
