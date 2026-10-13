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
        /// Ce qui a déjà été écrit : c'est lui qui permet de reprendre après une coupure.
        let ledger = TransferLedger()
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

    /// Relance un transfert interrompu. Il reprend où il s'était arrêté quand c'est sûr, sinon il recommence.
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isActive, jobs[id] != nil else { return }
        items[index].state = .waiting
        items[index].transferredBytes = 0
        items[index].completedFiles = 0
        items[index].startedAt = nil
        items[index].finishedAt = nil
        items[index].resumedFrom = nil
        items[index].resumeNote = nil
        items[index].notice = nil
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

    /// Retire les transferts terminés. Les échecs abandonnés emportent leurs fichiers partiels.
    func clearFinished() {
        let finished = items.filter { !$0.isActive }.map(\.id)
        items.removeAll { !$0.isActive }
        for id in finished {
            if let job = jobs[id] { discard(job) }
            jobs[id] = nil
        }
    }

    /// Fin de session : les partiels locaux des transferts non terminés ne survivent pas à Fil,
    /// puisque la reprise n'est valable que dans la session qui les a écrits.
    func removeLocalPartials() {
        jobs.values.forEach { $0.ledger.removeLocalPartials() }
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
            var resumable = false
            do {
                switch job.source {
                case .remote(let file, let folder):
                    try await TransferRunner.download(file, into: folder, via: job.provider, ledger: job.ledger, report: report)
                case .local(let url, let directory):
                    try await TransferRunner.upload(url, into: directory, via: job.provider, ledger: job.ledger, report: report)
                }
                outcome = .done
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                if Task.isCancelled {
                    outcome = .cancelled
                } else {
                    outcome = .failed(ReadableError.message(for: error))
                    resumable = Self.isInterruption(error)
                }
            }
            self?.finish(id, outcome, resumable: resumable)
        }
    }

    /// Une coupure laisse un partiel valable ; un refus du serveur, non.
    nonisolated static func isInterruption(_ error: Error) -> Bool {
        if let provider = error as? ProviderError { return provider.isInterruption }
        if let url = error as? URLError {
            switch url.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
            default: return false
            }
        }
        return false
    }

    private func finish(_ id: UUID, _ state: TransferItem.State, resumable: Bool) {
        tasks[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = state
            items[index].finishedAt = .now
            if state == .done, let total = items[index].totalBytes {
                items[index].transferredBytes = total
            }
            items[index].resumeNote = (state != .done && resumable) ? resumeNote(for: items[index], ledger: jobs[id]?.ledger) : nil
        }
        if let job = jobs[id] {
            if state == .done {
                job.ledger.reset()
            } else if !resumable {
                discard(job)
            }
        }
        if state == .done { jobs[id]?.onFinish?() }
        pump()
    }

    /// Efface les fichiers partiels d'un transfert qu'on ne reprendra pas.
    private func discard(_ job: Job) {
        let leftovers = job.ledger.takeLeftovers()
        guard !leftovers.isEmpty else { return }
        let provider = job.provider
        Task.detached(priority: .utility) {
            await TransferRunner.discard(leftovers, via: provider)
        }
    }

    private func resumeNote(for item: TransferItem, ledger: TransferLedger?) -> String? {
        guard ledger?.hasProgress == true else { return nil }
        if item.isFolder, item.completedFiles > 0 { return "Réessayer reprend après \(Format.files(item.completedFiles))." }
        if item.transferredBytes > 0 { return "Réessayer reprend vers \(Format.bytes(item.transferredBytes))." }
        return "Réessayer reprend là où il s'est arrêté."
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
        case .resumed(let bytes):
            items[index].resumedFrom = bytes
            items[index].transferredBytes = max(items[index].transferredBytes, bytes)
        case .fileCompleted(let count):
            items[index].completedFiles = max(items[index].completedFiles, count)
        case .destination(let url):
            items[index].localURL = url
        case .warning(let text):
            items[index].notice = text
        }
    }
}
