import Foundation
import Observation

/// État de la page « fichiers » d'une connexion ouverte.
@MainActor @Observable
final class BrowserModel {
    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum SortKey: Equatable, Sendable { case name, size, modified }

    let connection: RemoteConnection
    let home: RemotePath
    private(set) var path: RemotePath
    private(set) var files: [RemoteFile] = []
    private(set) var status: Status = .loading
    /// Actualisation d'un dossier déjà affiché.
    private(set) var isRefreshing = false
    /// Phrase de l'opération en cours (suppression, création de dossier).
    private(set) var activity: String?
    /// Dernière opération refusée, en clair.
    var notice: String?
    var selection: Set<RemoteFile.ID> = []
    /// Élément dont on demande le nouveau nom ; la vue montre la saisie tant qu'il est là.
    var renaming: RemoteFile?
    var filter = ""
    var sortKey: SortKey = .name
    var ascending = true

    @ObservationIgnored let provider: any RemoteFileProvider
    @ObservationIgnored let transfers: TransferQueue
    #if os(macOS)
    @ObservationIgnored private let edits: EditCoordinator
    @ObservationIgnored private let finder: FinderAccess?
    #endif
    @ObservationIgnored private let downloadFolder: @MainActor () -> URL
    /// Derniers listings vus, pour afficher tout de suite en revenant. Toujours relu derrière.
    @ObservationIgnored private var cache: [RemotePath: [RemoteFile]] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    #if os(macOS)
    init(connection: RemoteConnection, provider: any RemoteFileProvider, home: RemotePath, transfers: TransferQueue, edits: EditCoordinator = EditCoordinator(), finder: FinderAccess? = nil, downloadFolder: @escaping @MainActor () -> URL) {
        self.connection = connection
        self.finder = finder
        self.provider = provider
        self.home = home
        self.path = home
        self.transfers = transfers
        self.edits = edits
        self.downloadFolder = downloadFolder
        load(home)
    }
    #else
    init(connection: RemoteConnection, provider: any RemoteFileProvider, home: RemotePath, transfers: TransferQueue, downloadFolder: @escaping @MainActor () -> URL) {
        self.connection = connection
        self.provider = provider
        self.home = home
        self.path = home
        self.transfers = transfers
        self.downloadFolder = downloadFolder
        load(home)
    }
    #endif

    // MARK: Lecture

    var title: String {
        path.isRoot ? (connection.protocol.pathIsRoot ? connection.name : "Racine du serveur") : path.name
    }

    var canGoUp: Bool { path.parent != nil }

    var visibleFiles: [RemoteFile] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? files : files.filter { $0.name.localizedStandardContains(query) }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ordered: Bool
            switch sortKey {
            case .name:
                ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                ordered = (lhs.byteCount ?? -1, lhs.name) < (rhs.byteCount ?? -1, rhs.name)
            case .modified:
                ordered = (lhs.modifiedAt ?? .distantPast, lhs.name) < (rhs.modifiedAt ?? .distantPast, rhs.name)
            }
            return ascending ? ordered : !ordered
        }
    }

    var selectedFiles: [RemoteFile] {
        visibleFiles.filter { selection.contains($0.id) }
    }

    /// « 12 éléments · 340 Mo » ou, avec une sélection, « 3 sélectionnés sur 12 · 40 Mo ».
    var footnote: String {
        let chosen = selectedFiles
        let pool = chosen.isEmpty ? files : chosen
        let bytes = pool.compactMap(\.byteCount).reduce(0, +)
        let size = bytes > 0 ? " · \(Format.bytes(bytes))" : ""
        if chosen.isEmpty { return Format.items(files.count) + size }
        let label = chosen.count <= 1 ? "sélectionné" : "sélectionnés"
        return "\(Format.count(chosen.count)) \(label) sur \(Format.count(files.count))\(size)"
    }

    /// Phrase de l'attente en cours, s'il y en a une.
    var waitingPhrase: String? {
        if let activity { return activity }
        if status == .loading { return "Lecture de « \(path.isRoot ? connection.resolvedHost : path.name) »…" }
        if isRefreshing { return "Actualisation…" }
        return nil
    }

    // MARK: Navigation

    func navigate(to target: RemotePath) {
        guard target != path || status != .ready else { return refresh() }
        selection = []
        filter = ""
        load(target)
    }

    func refresh() {
        load(path)
    }

    func goUp() {
        guard let parent = path.parent else { return }
        let previous = path
        navigate(to: parent)
        selection = [previous.value]
    }

    /// Double-clic ou Entrée : un dossier s'ouvre, des fichiers se téléchargent.
    func open(_ ids: Set<RemoteFile.ID>) {
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        if chosen.count == 1, let only = chosen.first, only.kind != .file {
            openFolder(only)
        } else {
            download(chosen.filter { $0.kind == .file || $0.isDirectory })
        }
    }

    private func openFolder(_ file: RemoteFile) {
        guard file.kind == .link else { return navigate(to: file.path) }
        // Lien FTP de cible inconnue : on essaie comme dossier, sinon c'est un fichier.
        activity = "Ouverture de « \(file.name) »…"
        Task {
            let isFolder = (try? await provider.list(file.path)) != nil
            activity = nil
            if isFolder {
                navigate(to: file.path)
            } else {
                download([RemoteFile(name: file.name, path: file.path, kind: .file, isSymbolicLink: true)])
            }
        }
    }

    // MARK: Actions

    #if os(macOS)
    /// Un seul fichier est sélectionné, et c'est bien un fichier : on peut le modifier sur place.
    var canEditSelection: Bool {
        let chosen = selectedFiles
        return chosen.count == 1 && chosen[0].kind == .file
    }

    func editSelection() {
        guard canEditSelection else { return }
        edit(selectedFiles[0])
    }

    /// Ouvre le fichier dans l'éditeur ; chaque enregistrement repart vers le serveur.
    func edit(_ file: RemoteFile) {
        notice = edits.start(file, via: provider)
    }
    #endif

    func downloadSelection() {
        download(selectedFiles)
    }

    func download(_ chosen: [RemoteFile]) {
        guard !chosen.isEmpty else { return }
        transfers.download(chosen, via: provider, into: downloadFolder())
    }

    /// Noms déjà présents dans le dossier affiché, à confirmer avant de les remplacer.
    func conflicts(for urls: [URL]) -> [String] {
        let existing = Set(files.map(\.name.precomposedStringWithCanonicalMapping))
        return urls.map(LocalNaming.remoteName).filter(existing.contains)
    }

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let directory = path
        transfers.upload(urls, into: directory, via: provider) { [weak self] in
            guard let self else { return }
            self.cache[directory] = nil
            if self.path == directory { self.refresh() }
        }
    }

    // MARK: Finder

    #if os(macOS)
    /// WebDAV et kDrive seulement : le Finder monterait les autres en lecture seule, ou pas du tout.
    var canOpenInFinder: Bool { finder != nil && FinderMount.isSupported(connection.protocol) }

    /// Au-delà, la phrase d'attente dit que le serveur traîne. Le montage, lui, continue.
    @ObservationIgnored var finderPatience: Duration = .seconds(10)

    /// Monte la connexion comme volume (ou reprend celui qui l'est déjà) et y ouvre le dossier affiché.
    func openInFinder() {
        guard let finder, canOpenInFinder, activity == nil else { return }
        let url: URL
        switch FinderMount.target(for: connection) {
        case .blocked(let reason):
            notice = reason
            return
        case .url(let found):
            url = found
        }
        let shown = path
        let mounting = "Montage de « \(connection.name) » dans le Finder…"
        activity = mounting
        notice = nil
        let patience = finderPatience
        let slow = Task { [weak self] in
            try? await Task.sleep(for: patience)
            guard !Task.isCancelled, let self, self.activity == mounting else { return }
            self.activity = "« \(self.connection.resolvedHost) » met du temps à répondre. Le montage continue…"
        }
        Task {
            defer { slow.cancel() }
            do {
                let user = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
                let mountPoint = try await finder.volumes.mount(url, user: user, password: finder.password)
                finder.volumes.reveal(FinderMount.folder(for: shown, in: mountPoint))
            } catch {
                notice = ReadableError.message(for: error)
            }
            activity = nil
        }
    }
    #endif

    func delete(_ chosen: [RemoteFile]) {
        guard !chosen.isEmpty else { return }
        activity = chosen.count == 1 ? "Suppression de « \(chosen[0].name) »…" : "Suppression de \(Format.items(chosen.count))…"
        notice = nil
        Task {
            do {
                for file in chosen { try await provider.delete(file) }
            } catch {
                notice = ReadableError.message(for: error)
            }
            activity = nil
            selection.subtract(chosen.map(\.id))
            refresh()
        }
    }

    /// Raison pour laquelle ce nom de dossier ne convient pas, `nil` s'il convient.
    func folderNameProblem(_ name: String) -> String? {
        nameProblem(name, emptyReason: "Donne un nom au dossier.")
    }

    /// Raison pour laquelle `file` ne peut pas prendre ce nom, `nil` s'il le peut (ou s'il le porte déjà).
    func renameProblem(_ file: RemoteFile, to name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == file.name { return nil }
        #if os(macOS)
        if let session = edits.session(under: file.path, on: connection.id) {
            return "« \(session.name) » est ouvert dans l'éditeur. Termine la modification avant de renommer."
        }
        #endif
        // Un nom qui ne diffère que par la casse désigne le même fichier sur bien des serveurs : on l'autorise.
        return nameProblem(trimmed, emptyReason: "Donne un nom.", ignoring: file)
    }

    private func nameProblem(_ name: String, emptyReason: String, ignoring current: RemoteFile? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return emptyReason }
        if trimmed.contains("/") { return "Le nom ne peut pas contenir de « / »." }
        if trimmed == "." || trimmed == ".." { return "Ce nom est réservé." }
        // `move` remplace la destination : c'est ici, et nulle part ailleurs, qu'on évite d'écraser un voisin.
        if files.contains(where: { $0.name == trimmed && $0.path != current?.path }) { return "« \(trimmed) » existe déjà ici." }
        return nil
    }

    var canRenameSelection: Bool { selectedFiles.count == 1 }

    func beginRenamingSelection() {
        guard canRenameSelection else { return }
        renaming = selectedFiles[0]
    }

    func rename(_ file: RemoteFile, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != file.name else { return }
        if let problem = renameProblem(file, to: trimmed) {
            notice = problem
            return
        }
        let target = (file.path.parent ?? .root).appending(trimmed)
        activity = "Renommage de « \(file.name) »…"
        notice = nil
        Task {
            do {
                try await provider.move(file.path, to: target)
                // Les listings gardés sous l'ancien chemin ne désignent plus rien.
                cache = cache.filter { !$0.key.hasPrefix(file.path) }
                selection = [target.value]
            } catch {
                notice = ReadableError.message(for: error)
            }
            activity = nil
            refresh()
        }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard folderNameProblem(trimmed) == nil else { return }
        let target = path.appending(trimmed)
        activity = "Création de « \(trimmed) »…"
        notice = nil
        Task {
            do {
                try await provider.makeDirectory(target)
                selection = [target.value]
            } catch {
                notice = ReadableError.message(for: error)
            }
            activity = nil
            refresh()
        }
    }

    // MARK: Chargement

    private func load(_ target: RemotePath) {
        loadTask?.cancel()
        generation += 1
        let token = generation
        path = target
        if let cached = cache[target] {
            files = cached
            status = .ready
            isRefreshing = true
        } else {
            files = []
            status = .loading
        }
        loadTask = Task {
            do {
                let listing = try await provider.list(target)
                guard token == generation else { return }
                cache[target] = listing
                files = listing
                status = .ready
                selection = selection.intersection(listing.map(\.id))
            } catch {
                guard token == generation, !(error is CancellationError) else { return }
                // Le cache n'est jamais la vérité : en cas d'échec, on n'affiche pas une liste périmée.
                cache[target] = nil
                files = []
                status = .failed(ReadableError.message(for: error))
            }
            isRefreshing = false
        }
    }
}
