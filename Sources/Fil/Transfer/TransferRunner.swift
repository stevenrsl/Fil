import Foundation
import os

enum TransferEvent: Sendable {
    case inventory(files: Int)
    case planned(bytes: Int64, files: Int)
    case bytes(Int64)
    /// Le transfert reprend là où il s'était arrêté : ces octets sont déjà en place.
    case resumed(bytes: Int64)
    case fileCompleted(Int)
    case destination(URL)
    case warning(String)
}

/// Remontée des événements d'un transfert. Les octets sont limités à dix mises à jour par seconde.
struct TransferReport: Sendable {
    private let send: @Sendable (TransferEvent) -> Void
    private let throttle = Throttle(interval: 0.1)

    init(send: @escaping @Sendable (TransferEvent) -> Void) {
        self.send = send
    }

    func callAsFunction(_ event: TransferEvent) {
        if case .bytes = event, !throttle.shouldPass() { return }
        send(event)
    }

    /// Octets définitifs d'un fichier : toujours transmis.
    func settle(_ bytes: Int64) {
        send(.bytes(bytes))
    }

    final class Throttle: @unchecked Sendable {
        private let interval: TimeInterval
        private let lock = NSLock()
        private var last: Date = .distantPast

        init(interval: TimeInterval) { self.interval = interval }

        func shouldPass() -> Bool {
            lock.withLock {
                let now = Date()
                guard now.timeIntervalSince(last) >= interval else { return false }
                last = now
                return true
            }
        }
    }
}

/// Serveurs dont le renommage est refusé (compte en dépôt seul, par exemple) : pour eux, l'envoi
/// se fait directement sous le nom final, sans la protection d'un nom temporaire. Valable pour la session.
enum UploadPolicy {
    private static let refused = OSAllocatedUnfairLock(initialState: Set<UUID>())

    static func refusesRename(_ connectionID: UUID) -> Bool { refused.withLock { $0.contains(connectionID) } }
    static func markRenameRefused(_ connectionID: UUID) { refused.withLock { _ = $0.insert(connectionID) } }
}

/// Déroulé d'un transfert, hors du fil principal.
///
/// - Un envoi arrive sous `nom.filpart` et n'est renommé qu'une fois complet : le fichier en ligne
///   est soit l'ancienne version, soit la nouvelle entière, jamais un morceau.
/// - Un téléchargement s'écrit dans `nom.filpart` et prend son nom final une fois complet.
/// - Après une coupure, `ledger` permet de reprendre au lieu de recommencer.
enum TransferRunner {
    /// Au-delà de cette taille, on vérifie que le serveur a bien reçu tous les octets avant de renommer.
    /// En dessous, la réponse de fin de transfert du serveur suffit et on économise des allers-retours.
    static let verificationThreshold: Int64 = 4 * 1024 * 1024

    // MARK: Téléchargement

    static func download(_ file: RemoteFile, into folder: URL, via provider: any RemoteFileProvider, ledger: TransferLedger, report: TransferReport) async throws {
        guard file.isDirectory else {
            report(.planned(bytes: file.byteCount ?? 0, files: 1))
            let final = try await downloadFile(file, into: folder, via: provider, ledger: ledger, progress: FileProgress(report: report))
            report(.destination(final))
            return
        }

        let entries = try await provider.walk(file.path) { count in report(.inventory(files: count)) }
        let root: URL
        if let reused = ledger.rootFolder, FileManager.default.fileExists(atPath: reused.path) {
            root = reused
        } else {
            root = try LocalNaming.reserveFolder(named: file.name, in: folder)
            ledger.rootFolder = root
        }
        report(.destination(root))
        let files = entries.filter { !$0.isDirectory }
        report(.planned(bytes: files.reduce(0) { $0 + ($1.byteCount ?? 0) }, files: files.count))

        if let bulk = provider as? any DirectoryDownloadProvider, ledger.completedCount == 0 {
            try await bulk.downloadDirectory(file, entries: entries, to: root, progress: { report(.bytes($0)) })
            let total = files.reduce(Int64(0)) { $0 + ($1.byteCount ?? 0) }
            report.settle(total)
            report(.fileCompleted(files.count))
            return
        }

        let base = file.path.components.count
        func localFolder(for path: RemotePath) -> URL {
            path.components.dropFirst(base).dropLast().reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        }
        for directory in entries where directory.isDirectory {
            try FileManager.default.createDirectory(at: localFolder(for: directory.path).appendingPathComponent(directory.name, isDirectory: true), withIntermediateDirectories: true)
        }

        let tally = ByteTally(settled: ledger.completedBytes)
        if ledger.completedCount > 0 {
            report(.resumed(bytes: ledger.completedBytes))
            report(.fileCompleted(ledger.completedCount))
        }
        let remaining = files.filter { !ledger.isDone($0.path.value) }
        let folders = remaining.map { localFolder(for: $0.path) }
        try await forEach(remaining, width: provider.parallelFiles) { index, child in
            let progress = FileProgress(report: report, tally: tally, slot: index)
            let final = try await downloadFile(child, into: folders[index], via: provider, ledger: ledger, progress: progress)
            report.settle(tally.settle(index, LocalFile.size(of: final) ?? child.byteCount ?? 0))
            report(.fileCompleted(ledger.completedCount))
        }
    }

    private static func downloadFile(_ file: RemoteFile, into folder: URL, via provider: any RemoteFileProvider, ledger: TransferLedger, progress: FileProgress) async throws -> URL {
        let key = file.path.value
        var offset: Int64 = 0
        var reserved: TransferLedger.LocalPartial
        if let known = ledger.localPartial(key), FileManager.default.fileExists(atPath: known.partial.path) {
            reserved = known
            let resume = try await resumableDownloadOffset(known, file: file, via: provider)
            offset = resume.offset
            if offset == 0, let current = resume.modified, current != known.remoteModified {
                // Réécrit entre deux essais : on repart de zéro, et la nouvelle date devient la référence.
                reserved.remoteModified = current
                ledger.setLocalPartial(key, reserved)
            }
        } else {
            let (final, partial) = try LocalNaming.reserveFile(named: file.name, in: folder)
            reserved = TransferLedger.LocalPartial(partial: partial, final: final, remoteSize: file.byteCount, remoteModified: file.modifiedAt)
            ledger.setLocalPartial(key, reserved)
        }

        if offset > 0 { progress.resumed(offset) }
        // Fichier déjà entièrement là : il ne reste que le renommage.
        if !(offset > 0 && offset == file.byteCount) {
            try await provider.download(file, to: reserved.partial, resumingAt: offset, progress: progress.bytes)
        }

        let received = LocalFile.size(of: reserved.partial) ?? 0
        if let expected = file.byteCount, received < expected {
            // Un fichier qui a rétréci depuis le listing n'est pas une erreur : le serveur fait foi.
            let current = try? await provider.size(of: file.path)
            if current != received { throw ProviderError.incomplete(name: file.name, received: received, expected: expected) }
        }
        let final = try LocalNaming.complete(reserved.partial, as: reserved.final)
        ledger.markDone(key, size: received)
        return final
    }

    /// Décalage de reprise d'un téléchargement : seulement si le fichier distant n'a bougé ni de taille ni de date.
    /// Une coupure remonte, pour ne jamais écraser un partiel utile à cause d'un réseau qui flanche.
    /// `modified` : la date actuelle du fichier distant quand on a dû la relever (et qu'elle a changé).
    private static func resumableDownloadOffset(_ known: TransferLedger.LocalPartial, file: RemoteFile, via provider: any RemoteFileProvider) async throws -> (offset: Int64, modified: Date?) {
        guard let recorded = known.remoteSize, recorded > 0,
              let local = LocalFile.size(of: known.partial), local > 0, local <= recorded else { return (0, nil) }
        guard let current = try await partialSize(of: file.path, via: provider), current == recorded else { return (0, nil) }
        // Même taille ne veut pas dire même contenu : un journal réécrit pèse parfois pareil. La date tranche
        // quand le serveur en donne une ; sans date, on s'en tient à la taille.
        if let before = known.remoteModified, let now = try await modificationDate(of: file.path, via: provider), now != before {
            return (0, now)
        }
        return (local, nil)
    }

    /// Date actuelle d'un fichier distant, d'après le listing de son dossier ; `nil` si le serveur n'en donne pas.
    /// Une coupure remonte (la reprise réessaiera) ; toute autre erreur laisse la taille seule décider.
    private static func modificationDate(of path: RemotePath, via provider: any RemoteFileProvider) async throws -> Date? {
        do {
            return try await provider.list(path.parent ?? .root).first { $0.path == path }?.modifiedAt
        } catch {
            if error is CancellationError || (error as? ProviderError)?.isInterruption == true { throw error }
            return nil
        }
    }

    // MARK: Envoi

    static func upload(_ source: URL, into directory: RemotePath, via provider: any RemoteFileProvider, ledger: TransferLedger, report: TransferReport) async throws {
        let isFolder = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
        let destination = directory.appending(LocalNaming.remoteName(for: source))
        guard isFolder else {
            let size = LocalFile.size(of: source) ?? 0
            report(.planned(bytes: size, files: 1))
            try await uploadFile(source, to: destination, via: provider, ledger: ledger, progress: FileProgress(report: report))
            return
        }

        let (folders, files) = try inventory(source)
        report(.inventory(files: files.count))
        let total = files.reduce(0) { $0 + $1.size }
        try await provider.ensureDirectory(destination)
        for folder in folders {
            try Task.checkCancellation()
            try await provider.ensureDirectory(destination.appending(folder))
        }
        report(.planned(bytes: total, files: files.count))

        let tally = ByteTally(settled: ledger.completedBytes)
        if ledger.completedCount > 0 {
            report(.resumed(bytes: ledger.completedBytes))
            report(.fileCompleted(ledger.completedCount))
        }
        let remaining = files.filter { !ledger.isDone(destination.appending($0.relative).value) }
        try await forEach(remaining, width: provider.parallelFiles) { index, file in
            let progress = FileProgress(report: report, tally: tally, slot: index)
            try await uploadFile(file.url, to: destination.appending(file.relative), via: provider, ledger: ledger, progress: progress)
            report.settle(tally.settle(index, file.size))
            report(.fileCompleted(ledger.completedCount))
        }
    }

    /// Remplace un fichier distant, sous le nom exact donné, par le même chemin atomique que les envois :
    /// nom temporaire, contrôle de taille, renommage. Sert à renvoyer un fichier modifié sur place.
    static func replaceFile(_ source: URL, at destination: RemotePath, via provider: any RemoteFileProvider) async throws {
        try await uploadFile(source, to: destination, via: provider, ledger: TransferLedger(), progress: FileProgress(report: TransferReport { _ in }))
    }

    private static func uploadFile(_ source: URL, to destination: RemotePath, via provider: any RemoteFileProvider, ledger: TransferLedger, progress: FileProgress) async throws {
        let key = destination.value
        let size = LocalFile.size(of: source) ?? 0
        let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        let connectionID = provider.connection.id
        let direct = UploadPolicy.refusesRename(connectionID)
        let target = direct ? destination : destination.partialSibling

        var offset: Int64 = 0
        if !direct {
            if provider.canResumeUploads, let known = ledger.remotePartial(key),
               known.path == target, known.sourceSize == size, known.sourceModified == modified {
                // Taille réelle sur le serveur : ce qui est arrivé, pas ce que Fil croit avoir envoyé.
                if let remote = try await partialSize(of: target, via: provider), remote > 0, remote <= size { offset = remote }
            }
            ledger.setRemotePartial(key, TransferLedger.RemotePartial(path: target, sourceSize: size, sourceModified: modified))
        }

        if offset > 0 { progress.resumed(offset) }
        if !(offset > 0 && offset == size) {
            try await provider.upload(source, to: target, resumingAt: offset, progress: progress.bytes)
        }
        guard !direct else {
            ledger.markDone(key, size: size)
            return
        }

        // Contrôle avant de publier : un fichier trop court ne doit jamais prendre la place de l'ancien.
        if offset > 0 || size >= verificationThreshold, let remote = try await partialSizeIfKnown(of: target, via: provider), remote != size {
            throw ProviderError.incomplete(name: destination.name, received: remote, expected: size)
        }

        do {
            try await provider.move(target, to: destination)
        } catch {
            if error is CancellationError { throw error }
            if (error as? ProviderError)?.isInterruption == true { throw error }
            // Renommage refusé : on envoie directement, et on s'en souvient pour les fichiers suivants.
            UploadPolicy.markRenameRefused(connectionID)
            progress.report(.warning("envoi direct : ce serveur refuse le renommage"))
            try await provider.upload(source, to: destination, resumingAt: 0, progress: progress.bytes)
            Task.detached(priority: .utility) { try? await provider.delete(RemoteFile(name: target.name, path: target, kind: .file)) }
        }
        ledger.markDone(key, size: size)
    }

    /// Taille du partiel distant ; `nil` s'il est absent. Une coupure remonte pour que « Réessayer » la reprenne.
    private static func partialSize(of path: RemotePath, via provider: any RemoteFileProvider) async throws -> Int64? {
        do {
            return try await provider.size(of: path)
        } catch {
            if error is CancellationError || (error as? ProviderError)?.isInterruption == true { throw error }
            return nil
        }
    }

    /// Comme `partialSize`, mais une taille que le serveur ne sait pas donner n'empêche pas de publier.
    /// Un fichier absent, lui, est une anomalie : on renvoie 0 pour que la différence soit signalée.
    private static func partialSizeIfKnown(of path: RemotePath, via provider: any RemoteFileProvider) async throws -> Int64? {
        do {
            return try await provider.size(of: path) ?? 0
        } catch {
            if error is CancellationError || (error as? ProviderError)?.isInterruption == true { throw error }
            return nil
        }
    }

    // MARK: Fichiers en parallèle

    /// Passe `files` à `width` à la fois, chacun avec son rang. Un serveur qui refuse une connexion de plus ne fait
    /// pas échouer le transfert : le fichier retourne dans la file et on continue avec un ouvrier de moins.
    private static func forEach<File: Sendable>(_ files: [File], width: Int, _ body: @escaping @Sendable (Int, File) async throws -> Void) async throws {
        let line = WorkLine(count: files.count, workers: max(1, min(width, files.count)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<line.workers {
                group.addTask {
                    while let index = line.next() {
                        try Task.checkCancellation()
                        do {
                            try await body(index, files[index])
                        } catch ProviderError.connectionLimit where line.giveBack(index) {
                            return
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: Nettoyage

    /// Efface ce qu'un transfert abandonné a laissé : partiels locaux, et partiels distants au mieux.
    static func discard(_ leftovers: TransferLedger.Leftovers, via provider: any RemoteFileProvider) async {
        leftovers.localFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        for path in leftovers.remotePaths {
            try? await provider.delete(RemoteFile(name: path.name, path: path, kind: .file))
        }
    }

    // MARK: Inventaire local

    /// Sous-dossiers (parents d'abord) et fichiers d'un dossier local. `.DS_Store` n'est jamais envoyé.
    static func inventory(_ folder: URL) throws -> (folders: [String], files: [(url: URL, relative: String, size: Int64)]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw ProviderError.server("Impossible de lire le dossier « \(folder.lastPathComponent) ».")
        }
        let base = folder.standardizedFileURL.pathComponents.count
        var folders: [String] = []
        var files: [(URL, String, Int64)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent != ".DS_Store" else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/").precomposedStringWithCanonicalMapping
            if values.isDirectory == true {
                folders.append(relative)
            } else if values.isRegularFile == true {
                files.append((url, relative, Int64(values.fileSize ?? 0)))
            }
        }
        folders.sort { $0.split(separator: "/").count < $1.split(separator: "/").count }
        return (folders, files)
    }
}

/// Les rangs de fichiers qui restent à passer, et les ouvriers encore au travail.
private final class WorkLine: @unchecked Sendable {
    let workers: Int
    private let lock = NSLock()
    private var upcoming: Int = 0
    private let count: Int
    private var returned: [Int] = []
    private var active: Int

    init(count: Int, workers: Int) {
        self.count = count
        self.workers = workers
        self.active = workers
    }

    /// Le prochain rang ; `nil` : plus rien, l'ouvrier s'arrête.
    func next() -> Int? {
        lock.withLock {
            if let index = returned.popLast() { return index }
            guard upcoming < count else {
                active -= 1
                return nil
            }
            defer { upcoming += 1 }
            return upcoming
        }
    }

    /// Rend un fichier refusé faute de connexion, et retire son ouvrier. Impossible pour le dernier :
    /// personne ne le reprendrait, l'erreur doit remonter.
    func giveBack(_ index: Int) -> Bool {
        lock.withLock {
            guard active > 1 else { return false }
            active -= 1
            returned.append(index)
            return true
        }
    }
}

/// Octets d'un transfert : fichiers terminés, plus l'avancée de chacun de ceux en vol.
final class ByteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Int64
    private var inFlight: [Int: Int64] = [:]

    init(settled: Int64 = 0) { self.settled = settled }

    /// Le fichier `slot` en est à `bytes` depuis son début. Renvoie le total.
    func update(_ slot: Int, to bytes: Int64) -> Int64 {
        lock.withLock {
            inFlight[slot] = bytes
            return settled + inFlight.values.reduce(0, +)
        }
    }

    /// Le fichier `slot` est terminé et pèse `bytes`. Renvoie le total.
    func settle(_ slot: Int, _ bytes: Int64) -> Int64 {
        lock.withLock {
            inFlight[slot] = nil
            settled += bytes
            return settled + inFlight.values.reduce(0, +)
        }
    }
}

/// Avancée d'un fichier, ramenée au total du transfert dont il fait partie.
struct FileProgress: Sendable {
    let report: TransferReport
    var tally = ByteTally()
    var slot = 0

    @Sendable func bytes(_ bytes: Int64) { report(.bytes(tally.update(slot, to: bytes))) }
    func resumed(_ bytes: Int64) { report(.resumed(bytes: tally.update(slot, to: bytes))) }
}
