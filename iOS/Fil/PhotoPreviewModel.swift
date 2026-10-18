import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Aperçu des photos d'un dossier distant. Un serveur WebDAV ne fournit pas de vignette : le fichier
/// entier est téléchargé dans le cache, puis réduit à la taille de l'écran. Seules la photo affichée
/// et ses voisines restent en mémoire ; la suivante se charge dès que la photo affichée est prête.
/// Le cache est effacé à chaque lancement : il ne sert qu'à revenir en arrière et à enregistrer sans retélécharger.
@MainActor @Observable
final class PhotoPreviewModel: Identifiable {
    enum State: Equatable {
        case loading(received: Int64)
        case ready
        case failed(String)
    }

    let id = UUID()
    let files: [RemoteFile]
    var currentID: RemoteFile.ID {
        didSet { if oldValue != currentID { focus() } }
    }
    private(set) var states: [RemoteFile.ID: State] = [:]
    private(set) var images: [RemoteFile.ID: PreviewImage] = [:]
    /// Ce qu'est devenu le dernier enregistrement dans Fichiers.
    private(set) var message: String?

    @ObservationIgnored private let provider: any RemoteFileProvider
    @ObservationIgnored private var tasks: [RemoteFile.ID: Task<Void, Never>] = [:]

    /// Assez pour remplir l'écran du plus grand iPhone (2 796 px) sans garder 24 mégapixels en mémoire.
    nonisolated static let maxPixelSize = 2800

    init(files: [RemoteFile], startingAt file: RemoteFile, provider: any RemoteFileProvider) {
        self.files = files
        self.currentID = file.id
        self.provider = provider
    }

    var current: RemoteFile? { files.first { $0.id == currentID } }
    var index: Int { files.firstIndex { $0.id == currentID } ?? 0 }

    /// « 12 sur 1 703 ».
    var position: String { "\(Format.count(index + 1)) sur \(Format.count(files.count))" }

    /// Fichier complet en cache, prêt à partager ou à enregistrer.
    func cachedURL(for file: RemoteFile) -> URL? {
        guard states[file.id] == .ready else { return nil }
        return Self.cacheURL(for: file, on: provider.connection.id)
    }

    // MARK: Chargement

    func start() { focus() }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        images = [:]
        states = [:]
    }

    func retry(_ file: RemoteFile) {
        states[file.id] = nil
        load(file)
    }

    private var neighbours: [RemoteFile] {
        let index = index
        return files[max(0, index - 1)...min(files.count - 1, index + 1)].map { $0 }
    }

    private func focus() {
        message = nil
        guard !files.isEmpty else { return }
        let keep = Set(neighbours.map(\.id))
        // Une photo quittée n'est plus attendue : son téléchargement s'arrête, son image sort de la mémoire.
        for (id, task) in tasks where !keep.contains(id) {
            task.cancel()
            tasks[id] = nil
            states[id] = nil
        }
        for id in images.keys where !keep.contains(id) {
            images[id] = nil
            states[id] = nil
        }
        guard let current else { return }
        if states[current.id] == .ready {
            prefetchNext()
        } else {
            load(current)
        }
    }

    /// La photo suivante se prépare pendant qu'on regarde celle-ci : un seul téléchargement à la fois.
    private func prefetchNext() {
        let next = index + 1
        guard files.indices.contains(next) else { return }
        load(files[next])
    }

    private func load(_ file: RemoteFile) {
        guard images[file.id] == nil, tasks[file.id] == nil, states[file.id] == nil else { return }
        states[file.id] = .loading(received: 0)
        let provider = provider
        let cached = Self.cacheURL(for: file, on: provider.connection.id)
        let throttle = TransferReport.Throttle(interval: 0.2)
        let maxPixelSize = Self.maxPixelSize
        tasks[file.id] = Task { [weak self] in
            do {
                if !FileManager.default.fileExists(atPath: cached.path) {
                    try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Le nom final n'existe que complet : un aperçu interrompu ne laisse rien de trompeur.
                    let partial = cached.deletingLastPathComponent().appendingPathComponent("téléchargement.\(LocalNaming.partialExtension)")
                    try? FileManager.default.removeItem(at: partial)
                    try await provider.download(file, to: partial, resumingAt: 0) { bytes in
                        guard throttle.shouldPass() else { return }
                        Task { @MainActor in self?.received(bytes, for: file.id) }
                    }
                    try FileManager.default.moveItem(at: partial, to: cached)
                }
                let decoded = await Task.detached(priority: .userInitiated) {
                    PreviewImage.decode(cached, maxPixelSize: maxPixelSize)
                }.value
                self?.finish(file, decoded)
            } catch {
                self?.fail(file, error)
            }
        }
    }

    private func received(_ bytes: Int64, for id: RemoteFile.ID) {
        guard case .loading = states[id] else { return }
        states[id] = .loading(received: bytes)
    }

    private func finish(_ file: RemoteFile, _ decoded: PreviewImage?) {
        tasks[file.id] = nil
        guard !Task.isCancelled, states[file.id] != nil else { return }
        guard let decoded else {
            states[file.id] = .failed("Fil ne sait pas afficher « \(file.name) ». Tu peux toujours l'enregistrer.")
            return
        }
        images[file.id] = decoded
        states[file.id] = .ready
        if file.id == currentID { prefetchNext() }
    }

    private func fail(_ file: RemoteFile, _ error: Error) {
        tasks[file.id] = nil
        guard states[file.id] != nil else { return }
        states[file.id] = error is CancellationError ? nil : .failed(ReadableError.message(for: error))
    }

    // MARK: Enregistrer

    /// Copie la photo déjà téléchargée dans le dossier des téléchargements, sans repasser par le réseau.
    func saveCurrent(into folder: URL) {
        guard let file = current, let cached = cachedURL(for: file) else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Self.copy(cached, named: file.name, into: folder) } }.value
            switch result {
            case .success(let saved): message = "Enregistré dans Fichiers › Fil sous « \(saved.lastPathComponent) »."
            case .failure(let error): message = ReadableError.message(for: error)
            }
        }
    }

    nonisolated private static func copy(_ source: URL, named name: String, into folder: URL) throws -> URL {
        let (final, partial) = try LocalNaming.reserveFile(named: name, in: folder)
        do {
            try FileManager.default.removeItem(at: partial)
            try FileManager.default.copyItem(at: source, to: partial)
            return try LocalNaming.complete(partial, as: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    // MARK: Cache

    nonisolated static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aperçus", isDirectory: true)
    }

    /// Un dossier par version du fichier (chemin, taille, date) : un fichier modifié sur le serveur ne
    /// ressort jamais du cache. Le nom d'origine est gardé pour le partage.
    nonisolated static func cacheURL(for file: RemoteFile, on connection: UUID) -> URL {
        let version = "\(file.path.value)|\(file.byteCount ?? -1)|\(file.modifiedAt?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data: Data(version.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheFolder
            .appendingPathComponent(connection.uuidString, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(file.name)
    }

    nonisolated static func purgeCache() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }
}

/// Une photo réduite à la taille de l'écran, orientation EXIF appliquée.
struct PreviewImage: @unchecked Sendable {
    let cgImage: CGImage

    /// ImageIO lit JPEG, HEIC, PNG et l'aperçu intégré de la plupart des fichiers RAW.
    static func decode(_ url: URL, maxPixelSize: Int) -> PreviewImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(PreviewImage.init)
    }
}

extension RemoteFile {
    /// Une photo que l'aperçu sait montrer, d'après son extension.
    var isPreviewableImage: Bool {
        guard kind == .file else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }
}
