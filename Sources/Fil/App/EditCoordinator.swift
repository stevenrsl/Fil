import CryptoKit
import Foundation
import Observation

/// Modification d'un fichier distant sur place : télécharger, ouvrir dans l'éditeur, renvoyer à chaque enregistrement.
///
/// Garde-fous, dans cet ordre de priorité :
/// - la copie de l'utilisateur n'est jamais supprimée tant qu'elle contient des changements non envoyés ;
/// - rien n'écrase une version du serveur qui a changé entre-temps sans accord explicite ;
/// - chaque envoi est atomique (nom temporaire puis renommage) : le serveur ne voit jamais un fichier à moitié écrit ;
/// - un enregistrement qui ne change rien (même contenu) n'envoie rien.
@MainActor @Observable
final class EditCoordinator {
    private(set) var sessions: [EditSession] = []

    /// Au-delà, on n'ouvre pas : un éditeur n'a rien à faire d'un gros fichier, et on veut rester rapide.
    static let maximumBytes: Int64 = 64 * 1024 * 1024
    /// Une copie oubliée (Fil fermé avec des changements non envoyés) est gardée ce temps, puis effacée.
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    /// Ouvre un fichier local chez l'utilisateur. `false` : aucune application n'a su l'ouvrir.
    @ObservationIgnored var opener: @MainActor (URL) -> Bool
    /// Un envoi a modifié ce dossier distant : l'écran qui l'affiche peut se mettre à jour.
    @ObservationIgnored var onRemoteChanged: ((_ connectionID: UUID, _ directory: RemotePath) -> Void)?
    @ObservationIgnored let cacheFolder: URL
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var runtimes: [UUID: Runtime] = [:]

    /// Ce que l'on sait d'un fichier local à un instant : suffit à reconnaître un enregistrement.
    struct LocalStamp: Equatable, Sendable {
        let modified: Date
        let size: Int64
    }

    /// Ce que l'on sait d'un fichier distant : suffit à reconnaître que quelqu'un d'autre l'a modifié.
    struct RemoteStamp: Equatable, Sendable {
        let size: Int64?
        let modified: Date?
    }

    private struct Runtime {
        let provider: any RemoteFileProvider
        var baseline: RemoteStamp?
        /// Condensé du contenu tel que le serveur l'a : un enregistrement identique n'envoie rien.
        var lastHash: String?
        /// État du fichier local au dernier envoi réussi (ou au téléchargement).
        var syncedStamp: LocalStamp?
        /// État du fichier local au dernier essai d'envoi : on ne rejoue pas un échec en boucle.
        var attemptedStamp: LocalStamp?
        /// Vu une fois, pas encore deux : l'éditeur écrit peut-être encore.
        var candidate: LocalStamp?
        var busy = false
        var task: Task<Void, Never>?
    }

    init(
        cacheFolder: URL = EditCoordinator.defaultCacheFolder,
        pollInterval: Duration = .milliseconds(500),
        opener: @escaping @MainActor (URL) -> Bool = { _ in false }
    ) {
        self.cacheFolder = cacheFolder
        self.pollInterval = pollInterval
        self.opener = opener
    }

    /// Le cache est reconstructible, jamais la vérité : un dossier de plus d'une semaine est supprimé au lancement.
    static var defaultCacheFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Fil/Edits", isDirectory: true)
    }

    // MARK: Lecture

    /// Sessions dont l'enregistrement n'est pas (ou pas sûrement) parti : à signaler avant de quitter.
    var unsentSessions: [EditSession] {
        sessions.filter { session in
            if session.needsAttention || session.state == .uploading { return true }
            guard session.state == .editing, let runtime = runtimes[session.id], let stamp = Self.localStamp(session.localURL) else { return false }
            return stamp != runtime.syncedStamp
        }
    }

    // MARK: Ouvrir

    /// Ouvre `file` pour modification. Renvoie la raison d'un refus, `nil` si c'est parti.
    func start(_ file: RemoteFile, via provider: any RemoteFileProvider) -> String? {
        guard file.kind == .file else {
            return file.isDirectory ? "« \(file.name) » est un dossier : on ne modifie que des fichiers." : "« \(file.name) » est un lien dont la cible est inconnue : télécharge-le plutôt."
        }
        if let size = file.byteCount, size > Self.maximumBytes {
            return "« \(file.name) » est trop gros pour être modifié sur place (plus de \(Format.bytes(Self.maximumBytes))). Télécharge-le plutôt."
        }
        // Déjà ouvert : on le remet devant l'utilisateur plutôt que d'ouvrir une deuxième copie, qui se disputerait la première.
        if let existing = sessions.first(where: { $0.remotePath == file.path && $0.connectionID == provider.connection.id }) {
            if FileManager.default.fileExists(atPath: existing.localURL.path) {
                reopen(existing.id)
                return nil
            }
            // Un essai précédent a échoué avant d'avoir une copie : on repart de zéro.
            remove(existing.id, deleteCopy: true)
        }

        let id = UUID()
        let folder = cacheFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        let local = folder.appendingPathComponent(file.name)
        sessions.append(EditSession(id: id, connectionID: provider.connection.id, connectionName: provider.connection.name, remotePath: file.path, localURL: local, totalBytes: file.byteCount))
        runtimes[id] = Runtime(provider: provider)
        runtimes[id]?.task = Task { [weak self] in await self?.download(id, file: file, folder: folder, local: local) }
        return nil
    }

    private func download(_ id: UUID, file: RemoteFile, folder: URL, local: URL) async {
        guard let provider = runtimes[id]?.provider else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Le témoin du serveur se prend avant le téléchargement : un changement pendant celui-ci sera vu comme un conflit.
            let stamp = try await Self.remoteStamp(of: file.path, via: provider)
            try await provider.download(file, to: local) { [weak self] bytes in
                Task { @MainActor in self?.update(id) { $0.downloadedBytes = bytes } }
            }
            try Task.checkCancellation()
            guard let hash = await Self.sha256(of: local), let localStamp = Self.localStamp(local) else {
                throw ProviderError.server("La copie locale de « \(file.name) » est illisible.")
            }
            runtimes[id]?.baseline = stamp
            runtimes[id]?.lastHash = hash
            runtimes[id]?.syncedStamp = localStamp
            update(id) { $0.state = .editing }
            if !opener(local) {
                update(id) { $0.state = .failed("Aucune application ne sait ouvrir « \(file.name) ». Choisis un éditeur dans les réglages.") }
            }
            watch(id)
        } catch is CancellationError {
            remove(id, deleteCopy: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            update(id) { $0.state = .failed(ReadableError.message(for: error)) }
        }
    }

    // MARK: Surveiller

    private func watch(_ id: UUID) {
        runtimes[id]?.task?.cancel()
        let interval = pollInterval
        runtimes[id]?.task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.poll(id)
            }
        }
    }

    /// Un enregistrement se reconnaît à une date ou une taille qui change, vue **deux fois de suite** :
    /// un éditeur qui écrit par morceaux, ou qui remplace le fichier, n'est pas envoyé à mi-chemin.
    private func poll(_ id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }), var runtime = runtimes[id], !runtime.busy else { return }
        switch session.state {
        case .downloading, .uploading: return
        default: break
        }
        // Absent un instant : l'éditeur remplace le fichier. On attend.
        guard let stamp = Self.localStamp(session.localURL) else { return }
        if stamp == runtime.syncedStamp || stamp == runtime.attemptedStamp {
            runtime.candidate = nil
            runtimes[id] = runtime
            return
        }
        guard stamp == runtime.candidate else {
            runtime.candidate = stamp
            runtimes[id] = runtime
            return
        }
        runtimes[id]?.busy = true
        defer { runtimes[id]?.busy = false }
        guard let hash = await Self.sha256(of: session.localURL) else { return }
        // Enregistré sans rien changer : l'éditeur a seulement touché le fichier.
        if hash == runtime.lastHash {
            runtimes[id]?.syncedStamp = stamp
            runtimes[id]?.candidate = nil
            return
        }
        await upload(id, hash: hash, stamp: stamp, force: false)
    }

    // MARK: Envoyer

    private func upload(_ id: UUID, hash: String, stamp: LocalStamp, force: Bool) async {
        guard let session = sessions.first(where: { $0.id == id }), let provider = runtimes[id]?.provider else { return }
        runtimes[id]?.attemptedStamp = stamp
        update(id) { $0.state = .uploading }
        do {
            if !force {
                let current = try await Self.remoteStamp(of: session.remotePath, via: provider)
                guard let current else {
                    update(id) { $0.state = .conflict("« \(session.name) » n'existe plus sur le serveur.") }
                    return
                }
                if current != runtimes[id]?.baseline {
                    update(id) { $0.state = .conflict("« \(session.name) » a changé sur le serveur depuis que tu l'as ouvert.") }
                    return
                }
            }
            try await TransferRunner.replaceFile(session.localURL, at: session.remotePath, via: provider)
            // Le serveur vient de dater le fichier : c'est la nouvelle référence, pas un changement d'un tiers.
            runtimes[id]?.baseline = (try? await Self.remoteStamp(of: session.remotePath, via: provider)) ?? runtimes[id]?.baseline
            runtimes[id]?.lastHash = hash
            runtimes[id]?.syncedStamp = stamp
            runtimes[id]?.candidate = nil
            update(id) {
                $0.state = .editing
                $0.syncedAt = .now
            }
            onRemoteChanged?(session.connectionID, session.remotePath.parent ?? .root)
        } catch is CancellationError {
            update(id) { $0.state = .failed("Envoi interrompu.") }
        } catch {
            update(id) { $0.state = .failed(ReadableError.message(for: error)) }
        }
    }

    // MARK: Gestes de l'utilisateur

    /// « Écraser » : la version locale remplace celle du serveur, malgré le changement ou la disparition constatés.
    func overwrite(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }), case .conflict = session.state else { return }
        Task { [weak self] in
            guard let self, let stamp = Self.localStamp(session.localURL), let hash = await Self.sha256(of: session.localURL) else { return }
            await self.upload(id, hash: hash, stamp: stamp, force: true)
        }
    }

    /// « Réessayer » : renvoie ce qui n'est pas parti ; s'il n'y a rien à envoyer, rouvre l'éditeur.
    func retry(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }), case .failed = session.state else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let stamp = Self.localStamp(session.localURL), let hash = await Self.sha256(of: session.localURL) else {
                self.update(id) { $0.state = .failed("La copie locale de « \(session.name) » a disparu.") }
                return
            }
            if hash == self.runtimes[id]?.lastHash {
                self.update(id) { $0.state = .editing }
                self.runtimes[id]?.syncedStamp = stamp
                self.reopen(id)
            } else {
                await self.upload(id, hash: hash, stamp: stamp, force: false)
            }
        }
    }

    func reopen(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if !opener(session.localURL), session.state == .editing {
            update(id) { $0.state = .failed("Aucune application ne sait ouvrir « \(session.name) ». Choisis un éditeur dans les réglages.") }
        }
    }

    /// « Terminer » : un dernier enregistrement part d'abord ; la copie n'est supprimée que si tout est arrivé.
    func finish(_ id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }), session.state == .editing, runtimes[id]?.busy == false else { return }
        runtimes[id]?.task?.cancel()
        runtimes[id]?.busy = true
        if let stamp = Self.localStamp(session.localURL), stamp != runtimes[id]?.syncedStamp, let hash = await Self.sha256(of: session.localURL) {
            if hash == runtimes[id]?.lastHash {
                runtimes[id]?.syncedStamp = stamp
            } else {
                await upload(id, hash: hash, stamp: stamp, force: false)
            }
        }
        runtimes[id]?.busy = false
        if sessions.first(where: { $0.id == id })?.state == .editing {
            remove(id, deleteCopy: true)
        } else {
            // Conflit ou échec : la copie reste, et la surveillance reprend.
            watch(id)
        }
    }

    /// « Abandonner » : tout ce qui n'est pas parti est perdu. L'écran le fait confirmer.
    func discard(_ id: UUID) {
        remove(id, deleteCopy: true)
    }

    /// Fin de session : les copies dont tout est parti sont effacées ; les autres restent, avec leurs changements.
    func removeSyncedCopies() {
        let unsent = Set(unsentSessions.map(\.id))
        for session in sessions where !unsent.contains(session.id) {
            try? FileManager.default.removeItem(at: session.localURL.deletingLastPathComponent())
        }
    }

    /// Au lancement : les copies oubliées depuis plus d'une semaine disparaissent.
    func purgeStaleFolders(now: Date = .now) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if now.timeIntervalSince(modified) > Self.staleAfter {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    // MARK: Interne

    private func update(_ id: UUID, _ change: (inout EditSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
    }

    private func remove(_ id: UUID, deleteCopy: Bool) {
        runtimes[id]?.task?.cancel()
        if deleteCopy, let session = sessions.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: session.localURL.deletingLastPathComponent())
        }
        runtimes[id] = nil
        sessions.removeAll { $0.id == id }
    }

    static func localStamp(_ url: URL) -> LocalStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int64 else { return nil }
        return LocalStamp(modified: modified, size: size)
    }

    /// Taille et date du fichier distant d'après le listing de son dossier ; `nil` s'il n'y est plus.
    static func remoteStamp(of path: RemotePath, via provider: any RemoteFileProvider) async throws -> RemoteStamp? {
        try await provider.list(path.parent ?? .root).first { $0.path == path }.map { RemoteStamp(size: $0.byteCount, modified: $0.modifiedAt) }
    }

    static func sha256(of url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let input = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? input.close() }
            var hasher = SHA256()
            while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
