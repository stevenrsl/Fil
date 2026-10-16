import Foundation
import XCTest
@testable import Fil

/// Trousseau en mémoire : les tests ne touchent jamais au vrai Keychain.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]
    var failure: Error?

    func password(for connectionID: UUID) -> String? { lock.withLock { passwords[connectionID] } }
    func hasPassword(for connectionID: UUID) -> Bool { lock.withLock { passwords[connectionID] != nil } }

    func save(password: String, for connectionID: UUID, label: String) throws {
        if let failure { throw failure }
        lock.withLock { passwords[connectionID] = password }
    }

    func deletePassword(for connectionID: UUID) {
        lock.withLock { passwords[connectionID] = nil }
    }
}

/// Serveur simulé : une arborescence en mémoire, des pannes à la demande.
/// Il impose les préconditions d'un vrai serveur (décalage de reprise exact) : un bug de reprise échoue ici.
actor MockProvider: RemoteFileProvider {
    nonisolated let connection: RemoteConnection
    nonisolated let canResumeUploads: Bool
    private(set) var tree: [RemotePath: [RemoteFile]]
    private(set) var contents: [RemotePath: Data]
    private(set) var listCalls: [RemotePath] = []
    /// Appels de transfert dans l'ordre : « upload /a.filpart from 40 », « move /a.filpart -> /a »…
    private(set) var journal: [String] = []
    var home: RemotePath
    var connectError: Error?
    var listError: Error?
    var transferError: Error?
    /// Pause avant chaque bloc transféré, pour observer une file en mouvement.
    var chunkDelay: Duration = .zero
    var chunkSize = 1
    /// Coupe la connexion une fois ce nombre d'octets atteint (une seule fois, puis le serveur « revient »).
    var interruptAfter: Int?
    var refuseMove = false
    /// Le serveur annonce un envoi réussi mais garde un octet de moins.
    var dropLastUploadedByte = false
    private(set) var running = 0
    private(set) var maxRunning = 0
    /// Dates des fichiers : une horloge qui n'avance que quand on écrit, pour des tests sans attente.
    private var mtimes: [RemotePath: Date] = [:]
    private var tick = 0

    init(connection: RemoteConnection = RemoteConnection(name: "Simulé", host: "simule.test"), home: RemotePath = .root, files: [String: String] = [:], canResumeUploads: Bool = true, connectError: Error? = nil) {
        self.connection = connection
        self.home = home
        self.connectError = connectError
        self.canResumeUploads = canResumeUploads
        var tree: [RemotePath: [RemoteFile]] = [.root: []]
        var contents: [RemotePath: Data] = [:]
        for (rawPath, text) in files {
            let path = RemotePath(rawPath)
            contents[path] = Data(text.utf8)
            Self.insert(RemoteFile(name: path.name, path: path, kind: .file, byteCount: Int64(text.utf8.count), modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)), into: &tree)
            mtimes[path] = Date(timeIntervalSince1970: 1_800_000_000)
        }
        self.tree = tree
        self.contents = contents
    }

    private static func insert(_ file: RemoteFile, into tree: inout [RemotePath: [RemoteFile]]) {
        var current = RemotePath.root
        for component in file.path.components.dropLast() {
            let next = current.appending(component)
            if tree[next] == nil {
                tree[next] = []
                tree[current, default: []].append(RemoteFile(name: component, path: next, kind: .directory))
            }
            current = next
        }
        tree[current, default: []].removeAll { $0.path == file.path }
        tree[current, default: []].append(file)
        if file.isDirectory, tree[file.path] == nil { tree[file.path] = [] }
    }

    func set(connectError: Error?) { self.connectError = connectError }
    func set(listError: Error?) { self.listError = listError }
    func set(transferError: Error?) { self.transferError = transferError }
    func set(chunkDelay: Duration) { self.chunkDelay = chunkDelay }
    func set(chunkSize: Int) { self.chunkSize = chunkSize }
    func set(interruptAfter: Int?) { self.interruptAfter = interruptAfter }
    func set(refuseMove: Bool) { self.refuseMove = refuseMove }
    func set(dropLastUploadedByte: Bool) { self.dropLastUploadedByte = dropLastUploadedByte }

    /// Remplace (ou crée) un fichier du serveur, comme si quelqu'un d'autre l'avait modifié.
    func put(_ rawPath: String, _ text: String) {
        let path = RemotePath(rawPath)
        contents[path] = Data(text.utf8)
        touch(path)
        register(path)
    }

    private func touch(_ path: RemotePath) {
        tick += 1
        mtimes[path] = Date(timeIntervalSince1970: 1_800_000_000 + Double(tick))
    }

    private func register(_ path: RemotePath) {
        let size = Int64(contents[path]?.count ?? 0)
        Self.insert(RemoteFile(name: path.name, path: path, kind: .file, byteCount: size, modifiedAt: mtimes[path]), into: &tree)
    }

    func connect() async throws -> RemotePath {
        if let connectError { throw connectError }
        return home
    }

    func list(_ directory: RemotePath) async throws -> [RemoteFile] {
        listCalls.append(directory)
        if let listError { throw listError }
        guard let children = tree[directory] else { throw ProviderError.notFound(directory.name) }
        return children
    }

    func download(_ file: RemoteFile, to destination: URL, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        begin()
        defer { end() }
        journal.append("download \(file.path) from \(offset)")
        guard let data = contents[file.path] else { throw ProviderError.notFound(file.name) }
        if offset > 0, LocalFile.size(of: destination) != offset {
            throw ProviderError.server("Décalage local incohérent : \(LocalFile.size(of: destination) ?? -1) au lieu de \(offset).")
        }
        let output = try LocalFile.openForWriting(destination, resumingAt: offset)
        defer { try? output.close() }
        var position = Int(offset)
        while position < data.count {
            try Task.checkCancellation()
            if chunkDelay > .zero { try await Task.sleep(for: chunkDelay) }
            if let transferError { throw transferError }
            let end = min(position + chunkSize, data.count)
            try output.write(contentsOf: data.subdata(in: position..<end))
            position = end
            progress(Int64(position))
            if let limit = interruptAfter, position >= limit {
                interruptAfter = nil
                throw ProviderError.connectionLost
            }
        }
    }

    func upload(_ source: URL, to destination: RemotePath, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        begin()
        defer { end() }
        journal.append("upload \(destination) from \(offset)")
        let data = try Data(contentsOf: source)
        guard tree[destination.parent ?? .root] != nil else { throw ProviderError.notFound(destination.parent?.name ?? "/") }
        if offset > 0 {
            guard canResumeUploads, contents[destination]?.count == Int(offset) else {
                throw ProviderError.server("Décalage distant incohérent : \(contents[destination]?.count ?? -1) au lieu de \(offset).")
            }
        } else {
            contents[destination] = Data()
        }
        register(destination)
        var position = Int(offset)
        while position < data.count {
            try Task.checkCancellation()
            if chunkDelay > .zero { try await Task.sleep(for: chunkDelay) }
            if let transferError { throw transferError }
            let end = min(position + chunkSize, data.count)
            contents[destination, default: Data()].append(data.subdata(in: position..<end))
            position = end
            register(destination)
            progress(Int64(position))
            if let limit = interruptAfter, position >= limit {
                interruptAfter = nil
                throw ProviderError.connectionLost
            }
        }
        if dropLastUploadedByte, var stored = contents[destination], !stored.isEmpty {
            stored.removeLast()
            contents[destination] = stored
        }
        touch(destination)
        register(destination)
    }

    func size(of path: RemotePath) async throws -> Int64? {
        contents[path].map { Int64($0.count) }
    }

    func move(_ source: RemotePath, to destination: RemotePath) async throws {
        journal.append("move \(source) -> \(destination)")
        if refuseMove { throw ProviderError.accessDenied(destination.name) }
        if contents[source] == nil, tree[source] != nil {
            // Dossier : on déplace tout le sous-arbre, comme RNTO, MOVE ou rename le font côté serveur.
            let files = contents.filter { $0.key.hasPrefix(source) }
            let folders = tree.keys.filter { $0.hasPrefix(source) }
            let moved = { (path: RemotePath) in RemotePath(destination.value + path.value.dropFirst(source.value.count)) }
            remove(source)
            for folder in folders { Self.insert(RemoteFile(name: moved(folder).name, path: moved(folder), kind: .directory), into: &tree) }
            for (path, data) in files {
                contents[moved(path)] = data
                register(moved(path))
            }
            return
        }
        guard let data = contents[source] else { throw ProviderError.notFound(source.name) }
        contents[destination] = data
        contents[source] = nil
        tree[source.parent ?? .root]?.removeAll { $0.path == source }
        touch(destination)
        register(destination)
    }

    func makeDirectory(_ path: RemotePath) async throws {
        if tree[path] != nil { throw ProviderError.alreadyExists(path.name) }
        guard tree[path.parent ?? .root] != nil else { throw ProviderError.notFound(path.parent?.name ?? "/") }
        Self.insert(RemoteFile(name: path.name, path: path, kind: .directory), into: &tree)
    }

    func delete(_ file: RemoteFile) async throws {
        guard tree[file.parent]?.contains(where: { $0.path == file.path }) == true else { throw ProviderError.notFound(file.name) }
        remove(file.path)
    }

    private func remove(_ path: RemotePath) {
        for child in tree[path] ?? [] { remove(child.path) }
        contents[path] = nil
        tree[path] = nil
        tree[path.parent ?? .root]?.removeAll { $0.path == path }
    }

    private func begin() {
        running += 1
        maxRunning = max(maxRunning, running)
    }

    private func end() { running -= 1 }
}

private extension RemoteFile {
    var parent: RemotePath { path.parent ?? .root }
}

/// Dossier temporaire propre à un test.
func makeTemporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension XCTestCase {
    /// Attend qu'une condition sur l'état du fil principal devienne vraie.
    @MainActor
    func waitUntil(timeout: TimeInterval = 5, _ message: String = "condition", _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Délai dépassé : \(message)")
    }
}
