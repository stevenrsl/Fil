import CoreTransferable
import Foundation
import UniformTypeIdentifiers

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

    /// Garde un fichier reçu de Photos : le système l'efface dès qu'on lui rend la main.
    static func keep(_ file: URL) throws -> URL {
        let box = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let copy = box.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Deux éléments de Photos peuvent porter le même nom (`image.heic`) : chacun reçoit le sien,
    /// « image (2).heic », sans quoi le second remplacerait le premier sur le serveur.
    static func distinctNames(_ urls: [URL]) throws -> [URL] {
        var taken: Set<String> = []
        return try urls.map { url in
            let unique = LocalNaming.available(url) { taken.contains($0.lastPathComponent) }
            taken.insert(unique.lastPathComponent)
            guard unique != url else { return url }
            try FileManager.default.moveItem(at: url, to: unique)
            return unique
        }
    }

    /// Au lancement : la file de la session précédente n'existe plus, ses copies ne servent à rien.
    static func purge() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Une photo ou une vidéo choisie dans Photos, recopiée telle quelle (format d'origine, HEIC compris)
/// dans le dossier des envois. Aucun accès à la photothèque n'est demandé : le sélecteur ne livre que
/// ce que l'utilisateur a choisi.
struct StagedMedia: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try StagedMedia(url: UploadStaging.keep(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            try StagedMedia(url: UploadStaging.keep(received.file))
        }
    }
}
