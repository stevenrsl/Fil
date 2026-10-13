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
actor MockProvider: RemoteFileProvider {
    nonisolated let connection: RemoteConnection
    private(set) var tree: [RemotePath: [RemoteFile]]
    private(set) var contents: [RemotePath: Data]
    private(set) var listCalls: [RemotePath] = []
    var home: RemotePath
    var connectError: Error?
    var listError: Error?
    var transferError: Error?
    /// Pause avant chaque bloc transféré, pour observer une file en mouvement.
    var chunkDelay: Duration = .zero
    private(set) var running = 0
    private(set) var maxRunning = 0

    init(connection: RemoteConnection = RemoteConnection(name: "Simulé", host: "simule.test"), home: RemotePath = .root, files: [String: String] = [:]) {
        self.connection = connection
        self.home = home
        var tree: [RemotePath: [RemoteFile]] = [.root: []]
        var contents: [RemotePath: Data] = [:]
        for (rawPath, text) in files {
            let path = RemotePath(rawPath)
            contents[path] = Data(text.utf8)
            Self.insert(RemoteFile(name: path.name, path: path, kind: .file, byteCount: Int64(text.utf8.count)), into: &tree)
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

    func download(_ file: RemoteFile, to destination: URL, progress: @escaping ProgressHandler) async throws {
        begin()
        defer { end() }
        guard let data = contents[file.path] else { throw ProviderError.notFound(file.name) }
        var written = Data()
        for byte in data {
            try Task.checkCancellation()
            if chunkDelay > .zero { try await Task.sleep(for: chunkDelay) }
            if let transferError { throw transferError }
            written.append(byte)
            progress(Int64(written.count))
        }
        try written.write(to: destination)
    }

    func upload(_ source: URL, to destination: RemotePath, progress: @escaping ProgressHandler) async throws {
        begin()
        defer { end() }
        let data = try Data(contentsOf: source)
        if chunkDelay > .zero { try await Task.sleep(for: chunkDelay) }
        try Task.checkCancellation()
        if let transferError { throw transferError }
        guard tree[destination.parent ?? .root] != nil else { throw ProviderError.notFound(destination.parent?.name ?? "/") }
        contents[destination] = data
        Self.insert(RemoteFile(name: destination.name, path: destination, kind: .file, byteCount: Int64(data.count)), into: &tree)
        progress(Int64(data.count))
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
