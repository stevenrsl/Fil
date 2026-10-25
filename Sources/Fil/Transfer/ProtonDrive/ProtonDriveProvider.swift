import Foundation

#if os(macOS)

/// Adaptateur du CLI officiel. Proton Drive reste chiffré par le CLI, jamais par Fil.
final class ProtonDriveProvider: DirectoryDownloadProvider, @unchecked Sendable {
    let connection: RemoteConnection
    let canResumeUploads = false
    private let cli = ProtonDriveCLI()
    private let base: String

    init(connection: RemoteConnection) {
        self.connection = connection
        let configured = connection.path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.base = configured.isEmpty ? "/my-files" : RemotePath(configured).value
    }

    func connect() async throws -> RemotePath {
        let path = base
        let output = try await runWithLoginRetry(Self.listArguments(path))
        guard output.status == 0 else { throw Self.error(from: output, subject: path) }
        return RemotePath(path)
    }

    func list(_ directory: RemotePath) async throws -> [RemoteFile] {
        let remote = path(directory)
        let output = try await runWithLoginRetry(Self.listArguments(remote))
        guard output.status == 0 else { throw Self.error(from: output, subject: remote) }
        return Self.files(from: output.standardOutput, parent: RemotePath(remote))
    }

    func download(_ file: RemoteFile, to destination: URL, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        // Le CLI repart du début. Un dossier isolé évite tout conflit avec un fichier local existant.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Fil-Proton-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let monitor = Self.monitor(staging, progress: progress)
        defer { monitor.cancel() }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = try await runWithLoginRetry(["filesystem", "download", file.path.value, staging.path])
        guard output.status == 0 else { throw Self.error(from: output, subject: file.name) }
        let downloaded = staging.appendingPathComponent(file.name)
        if downloaded.standardizedFileURL != destination.standardizedFileURL,
           FileManager.default.fileExists(atPath: downloaded.path) {
            try FileManager.default.removeItemIfExists(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)
        }
        if let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber {
            progress(size.int64Value)
        }
    }

    func downloadDirectory(_ directory: RemoteFile, entries: [RemoteFile], to destination: URL, progress: @escaping ProgressHandler) async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Fil-Proton-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let monitor = Self.monitor(staging, progress: progress)
        defer { monitor.cancel() }
        let output = try await runWithLoginRetry(["filesystem", "download", directory.path.value, staging.path])
        guard output.status == 0 else { throw Self.error(from: output, subject: directory.name) }
        try Task.checkCancellation()
        let downloaded = staging.appendingPathComponent(directory.name, isDirectory: true)
        // Vérifier l'inventaire avant de publier le dossier, y compris si le CLI termine partiellement.
        for entry in entries {
            let relative = entry.path.components.dropFirst(directory.path.components.count)
            let local = relative.reduce(downloaded) { $0.appendingPathComponent($1) }
            guard FileManager.default.fileExists(atPath: local.path) else { throw ProviderError.incomplete(name: entry.name, received: 0, expected: entry.byteCount ?? 0) }
            if !entry.isDirectory, let expected = entry.byteCount {
                let received = LocalFile.size(of: local) ?? 0
                guard received == expected else { throw ProviderError.incomplete(name: entry.name, received: received, expected: expected) }
            }
        }
        for child in try FileManager.default.contentsOfDirectory(at: downloaded, includingPropertiesForKeys: nil) {
            try FileManager.default.moveItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
    }

    private static func monitor(_ directory: URL, progress: @escaping ProgressHandler) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(downloadedBytes(in: directory))
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private static func downloadedBytes(in directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return bytes
    }

    func upload(_ source: URL, to destination: RemotePath, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        guard offset == 0 else { throw ProviderError.server("La reprise des envois Proton Drive n'est pas encore disponible.") }
        let parent = destination.parent ?? .root
        let remoteParent = path(parent)
        // Le CLI prend un dossier cible et conserve le nom local. Préparer le nom demandé
        // par TransferRunner (notamment .filpart), sans modifier le fichier de l'utilisateur.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Fil-Proton-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.name)
        try FileManager.default.copyItem(at: source, to: staged)
        let output = try await runWithLoginRetry(["filesystem", "upload", "--file-conflict-strategy", "create-new-revision", staged.path, remoteParent])
        guard output.status == 0 else { throw Self.error(from: output, subject: destination.name) }
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress(size)
    }

    func size(of path: RemotePath) async throws -> Int64? {
        guard let file = try await list(path.parent ?? .root).first(where: { $0.path == path }) else { return nil }
        return file.byteCount
    }

    func move(_ source: RemotePath, to destination: RemotePath) async throws {
        try await moveReplacing(source, to: destination, rename: { source, destination in
            try await self.rename(source, to: destination)
        }, exists: { path in
            try await self.list(path.parent ?? .root).contains { $0.path == path }
        }, remove: { path in
            try await self.delete(RemoteFile(name: path.name, path: path, kind: .file))
        })
    }

    private func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        let output: ProcessRunner.CapturedOutput
        if source.parent == destination.parent {
            output = try await runWithLoginRetry(["filesystem", "rename", path(source), destination.name])
        } else {
            guard source.name == destination.name else {
                throw ProviderError.server("Déplace puis renomme ce fichier Proton Drive en deux étapes.")
            }
            output = try await runWithLoginRetry(["filesystem", "move", path(source), path(destination.parent ?? .root)])
        }
        guard output.status == 0 else { throw Self.error(from: output, subject: destination.name) }
    }

    func makeDirectory(_ path: RemotePath) async throws {
        let output = try await runWithLoginRetry(["filesystem", "create-folder", self.path(path.parent ?? .root), path.name])
        guard output.status == 0 else { throw Self.error(from: output, subject: path.name) }
    }

    func delete(_ file: RemoteFile) async throws {
        let output = try await runWithLoginRetry(["filesystem", "trash", path(file.path)])
        guard output.status == 0 else { throw Self.error(from: output, subject: file.name) }
    }

    private func path(_ remote: RemotePath) -> String {
        if remote.isRoot { return base }
        return base == "/my-files" || remote.value.hasPrefix("/my-files") ? remote.value : base + remote.value
    }

    private func runWithLoginRetry(_ arguments: [String]) async throws -> ProcessRunner.CapturedOutput {
        let output = try await cli.run(arguments)
        try Task.checkCancellation()
        guard output.status != 0 else { return output }
        let text = (output.standardOutput + output.errorOutput).lowercased()
        guard !output.errorOutput.lowercased().contains("command not found"),
              text.contains("not authenticated") || text.contains("not logged in") || text.contains("session expired") else { return output }
        _ = try await cli.run(["auth", "login"], timeout: .seconds(15 * 60))
        return try await cli.run(arguments)
    }

    static func listArguments(_ path: String) -> [String] {
        ["filesystem", "list", "--json", path]
    }

    static func error(from output: ProcessRunner.CapturedOutput, subject: String) -> ProviderError {
        let text = output.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().contains("command not found") {
            return .server("Commande incompatible avec le CLI Proton Drive : \(text)")
        }
        if text.lowercased().contains("node not found") { return .notFound(subject) }
        if text.lowercased().contains("permission") || text.lowercased().contains("access") { return .accessDenied(subject) }
        return .server(text.isEmpty ? "Le CLI Proton Drive a échoué pour « \(subject) »." : text)
    }

    static func files(from output: String, parent: RemotePath) -> [RemoteFile] {
        guard let objects = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            let nameValue = object["name"] as? String
            let nameObject = object["name"] as? [String: Any]
            let name = nameValue
                ?? (nameObject?["ok"] as? Bool == true ? nameObject?["value"] as? String : nil)
                ?? (object["path"] as? String)?.split(separator: "/").last.map(String.init)
            guard let name, !name.isEmpty else { return nil }
            let type = (object["type"] as? String)?.lowercased()
            let directory = type == "folder" || type == "directory" || type == "dir"
            let revision = object["activeRevision"] as? [String: Any]
            let size = (revision?["claimedSize"] as? NSNumber)?.int64Value
            let modified = (object["modificationTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let objectPath = object["path"] as? String
            let remotePath = objectPath.map(RemotePath.init) ?? parent.appending(name)
            return RemoteFile(name: name, path: remotePath, kind: directory ? .directory : .file, byteCount: size, modifiedAt: modified)
        }
    }
}

#endif
