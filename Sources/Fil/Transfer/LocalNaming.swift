import Foundation

/// Noms locaux sans collision. Toute réservation passe par le même verrou : deux téléchargements
/// simultanés d'un même nom ne peuvent pas choisir la même destination.
enum LocalNaming {
    static let partialExtension = "filpart"
    private static let lock = NSLock()

    /// « rapport.pdf » → « rapport (2).pdf » quand `isTaken` répond oui.
    static func available(_ url: URL, isTaken: (URL) -> Bool) -> URL {
        guard isTaken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = folder.appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
            if !isTaken(candidate) { return candidate }
            index += 1
        }
    }

    /// Nom à donner côté serveur : forme composée (NFC). macOS fournit des noms décomposés,
    /// qu'un serveur Linux afficherait en double d'un nom identique en apparence.
    static func remoteName(for url: URL) -> String {
        url.lastPathComponent.precomposedStringWithCanonicalMapping
    }

    static func partial(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(partialExtension)")
    }

    /// Choisit le nom final et crée tout de suite le fichier partiel qui le réserve.
    static func reserveFile(named name: String, in folder: URL) throws -> (final: URL, partial: URL) {
        try lock.withLock {
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let final = available(folder.appendingPathComponent(name)) { candidate in
                manager.fileExists(atPath: candidate.path) || manager.fileExists(atPath: partial(for: candidate).path)
            }
            let partial = partial(for: final)
            guard manager.createFile(atPath: partial.path, contents: nil) else {
                throw ProviderError.server("Impossible de créer « \(final.lastPathComponent) » dans « \(folder.lastPathComponent) ».")
            }
            return (final, partial)
        }
    }

    /// Remplace le partiel par le fichier final ; si le nom a été pris entre-temps, prend le suivant.
    static func complete(_ partial: URL, as final: URL) throws -> URL {
        try lock.withLock {
            let manager = FileManager.default
            let target = available(final) { manager.fileExists(atPath: $0.path) }
            try manager.moveItem(at: partial, to: target)
            return target
        }
    }

    static func reserveFolder(named name: String, in folder: URL) throws -> URL {
        try lock.withLock {
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = available(folder.appendingPathComponent(name, isDirectory: true)) { manager.fileExists(atPath: $0.path) }
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            return target
        }
    }
}

/// Fichiers locaux partiels : création, ou reprise à la suite de ce qui est déjà écrit.
enum LocalFile {
    /// Avec `offset` > 0, le fichier garde ses `offset` premiers octets et l'écriture continue derrière.
    static func openForWriting(_ url: URL, resumingAt offset: Int64) throws -> FileHandle {
        if offset <= 0 {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ProviderError.server("Impossible de créer « \(url.lastPathComponent) » sur ce Mac.")
            }
            return try FileHandle(forWritingTo: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seek(toOffset: UInt64(offset))
        return handle
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }
}
