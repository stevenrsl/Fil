import Foundation
import Observation

/// File des transferts : quelques-uns à la fois, les autres attendent leur tour.
/// Un transfert garde son fournisseur : il continue même si l'on quitte la connexion.
@MainActor @Observable
final class TransferQueue {
    private(set) var items: [TransferItem] = []
    let maxConcurrent: Int

    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    struct Job {
        enum Source {
            case remote(RemoteFile, folder: URL)
            case local(URL, directory: RemotePath)
        }
        let provider: any RemoteFileProvider
        let source: Source
        let onFinish: (@MainActor () -> Void)?
    }

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    var activeCount: Int { items.filter(\.isActive).count }
    var hasActive: Bool { items.contains(where: \.isActive) }
    var hasFinished: Bool { items.contains { !$0.isActive } }

    /// « 2 en cours · 3,2 Mo/s » ou « Tout est terminé ».
    func summary(now: Date) -> String {
        let running = items.filter { $0.state == .running }
        let waiting = items.filter { $0.state == .waiting || $0.state == .preparing }.count
        let failed = items.filter { if case .failed = $0.state { true } else { false } }.count
        var parts: [String] = []
        if !running.isEmpty { parts.append("\(Format.count(running.count)) en cours") }
        if waiting > 0 { parts.append("\(Format.count(waiting)) en attente") }
        let rate = running.compactMap { $0.rate(now: now) }.reduce(0, +)
        if rate > 0 { parts.append(Format.rate(rate)) }
        if failed > 0 { parts.append(Format.plural(failed, "échec", "échecs")) }
        return parts.isEmpty ? "Tout est terminé" : parts.joined(separator: " · ")
    }

    // MARK: Ajouter

    func download(_ files: [RemoteFile], via provider: any RemoteFileProvider, into folder: URL) {
        for file in files {
            let item = TransferItem(
                direction: .download,
                name: file.name,
                isFolder: file.isDirectory,
                connectionName: provider.connection.name,
                remotePath: file.path,
                localURL: folder,
                totalBytes: file.byteCount
            )
            enqueue(item, Job(provider: provider, source: .remote(file, folder: folder), onFinish: nil))
        }
    }

    func upload(_ urls: [URL], into directory: RemotePath, via provider: any RemoteFileProvider, onFinish: (@MainActor () -> Void)? = nil) {
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = isFolder ? nil : (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            let item = TransferItem(
                direction: .upload,
                name: LocalNaming.remoteName(for: url),
                isFolder: isFolder,
                connectionName: provider.connection.name,
                remotePath: directory.appending(LocalNaming.remoteName(for: url)),
                localURL: url,
                totalBytes: size
            )
            enqueue(item, Job(provider: provider, source: .local(url, directory: directory), onFinish: onFinish))
        }
    }

    // MARK: Piloter

    func cancel(_ id: UUID) {
        if let task = tasks[id] {
            task.cancel()
        } else if let index = items.firstIndex(where: { $0.id == id }), items[index].isActive {
            // Pas encore parti : rien à nettoyer, et il reste possible de le relancer.
            items[index].state = .cancelled
            items[index].finishedAt = .now
        }
    }

    func cancelAll() {
        for item in items where item.isActive { cancel(item.id) }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isActive, jobs[id] != nil else { return }
        items[index].state = .waiting
        items[index].transferredBytes = 0
        items[index].completedFiles = 0
        items[index].startedAt = nil
        items[index].finishedAt = nil
        if items[index].direction == .download, case .remote(_, let folder) = jobs[id]?.source {
            items[index].localURL = folder
        }
        pump()
    }

    func canRetry(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }), jobs[id] != nil else { return false }
        switch item.state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    func clearFinished() {
        let finished = items.filter { !$0.isActive }.map(\.id)
        items.removeAll { !$0.isActive }
        finished.forEach { jobs[$0] = nil }
    }

    // MARK: Exécution

    private func enqueue(_ item: TransferItem, _ job: Job) {
        items.append(item)
        jobs[item.id] = job
        pump()
    }

    private func pump() {
        var running = tasks.count
        for item in items where item.state == .waiting && running < maxConcurrent {
            start(item.id)
            running += 1
        }
    }

    private func start(_ id: UUID) {
        guard let job = jobs[id], let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = items[index].isFolder ? .preparing : .running
        items[index].startedAt = .now
        let report = TransferReport { [weak self] event in
            Task { @MainActor in self?.apply(event, to: id) }
        }
        tasks[id] = Task { [weak self] in
            let outcome: TransferItem.State
            do {
                switch job.source {
                case .remote(let file, let folder):
                    try await TransferRunner.download(file, into: folder, via: job.provider, report: report)
                case .local(let url, let directory):
                    try await TransferRunner.upload(url, into: directory, via: job.provider, report: report)
                }
                outcome = .done
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed(ReadableError.message(for: error))
            }
            self?.finish(id, outcome)
        }
    }

    private func finish(_ id: UUID, _ state: TransferItem.State) {
        tasks[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = state
            items[index].finishedAt = .now
            if state == .done, let total = items[index].totalBytes {
                items[index].transferredBytes = total
            }
        }
        if state == .done { jobs[id]?.onFinish?() }
        pump()
    }

    private func apply(_ event: TransferEvent, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        switch event {
        case .inventory(let files):
            items[index].fileCount = files
        case .planned(let bytes, let files):
            items[index].totalBytes = bytes
            items[index].fileCount = files
            items[index].state = .running
            items[index].startedAt = .now
        case .bytes(let bytes):
            items[index].transferredBytes = max(items[index].transferredBytes, bytes)
        case .fileCompleted(let count):
            items[index].completedFiles = max(items[index].completedFiles, count)
        case .destination(let url):
            items[index].localURL = url
        }
    }
}

enum TransferEvent: Sendable {
    case inventory(files: Int)
    case planned(bytes: Int64, files: Int)
    case bytes(Int64)
    case fileCompleted(Int)
    case destination(URL)
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

/// Déroulé d'un transfert, hors du fil principal.
enum TransferRunner {
    static func download(_ file: RemoteFile, into folder: URL, via provider: any RemoteFileProvider, report: TransferReport) async throws {
        guard file.isDirectory else {
            report(.planned(bytes: file.byteCount ?? 0, files: 1))
            let final = try await downloadFile(file, named: file.name, into: folder, via: provider, report: report) { $0 }
            report(.destination(final))
            return
        }

        let entries = try await provider.walk(file.path) { count in report(.inventory(files: count)) }
        let root = try LocalNaming.reserveFolder(named: file.name, in: folder)
        report(.destination(root))
        let files = entries.filter { !$0.isDirectory }
        report(.planned(bytes: files.reduce(0) { $0 + ($1.byteCount ?? 0) }, files: files.count))

        let base = file.path.components.count
        func localFolder(for path: RemotePath) -> URL {
            path.components.dropFirst(base).dropLast().reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        }
        for directory in entries where directory.isDirectory {
            try FileManager.default.createDirectory(at: localFolder(for: directory.path).appendingPathComponent(directory.name, isDirectory: true), withIntermediateDirectories: true)
        }
        var done: Int64 = 0
        for (index, child) in files.enumerated() {
            try Task.checkCancellation()
            let offset = done
            let final = try await downloadFile(child, named: child.name, into: localFolder(for: child.path), via: provider, report: report) { offset + $0 }
            done += (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int64) ?? child.byteCount ?? 0
            report.settle(done)
            report(.fileCompleted(index + 1))
        }
    }

    private static func downloadFile(_ file: RemoteFile, named name: String, into folder: URL, via provider: any RemoteFileProvider, report: TransferReport, total: @escaping @Sendable (Int64) -> Int64) async throws -> URL {
        let (final, partial) = try LocalNaming.reserveFile(named: name, in: folder)
        do {
            try await provider.download(file, to: partial) { bytes in report(.bytes(total(bytes))) }
            return try LocalNaming.complete(partial, as: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    static func upload(_ source: URL, into directory: RemotePath, via provider: any RemoteFileProvider, report: TransferReport) async throws {
        let isFolder = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
        let destination = directory.appending(LocalNaming.remoteName(for: source))
        guard isFolder else {
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            report(.planned(bytes: size, files: 1))
            try await provider.upload(source, to: destination) { report(.bytes($0)) }
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
        var done: Int64 = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let offset = done
            try await provider.upload(file.url, to: destination.appending(file.relative)) { report(.bytes(offset + $0)) }
            done += file.size
            report.settle(done)
            report(.fileCompleted(index + 1))
        }
    }

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
