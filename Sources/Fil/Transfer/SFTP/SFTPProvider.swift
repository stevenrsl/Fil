import Foundation

/// SFTP par OpenSSH (`ssh -s sftp`) et une implémentation Swift du protocole version 3.
/// Lectures et écritures sont pipelinées : plusieurs blocs en vol pour masquer la latence.
actor SFTPProvider: RemoteFileProvider {
    nonisolated let connection: RemoteConnection
    private let launch: SFTPChannel.Launch
    private let extraOptions: [String]
    private var channel: SFTPChannel?
    private var opening: Task<SFTPChannel, Error>?

    static let blockSize: UInt32 = 32_768
    static let window = 64

    /// `extraOptions` : options `ssh` supplémentaires, réservées aux tests (clé, `known_hosts` temporaire).
    init(connection: RemoteConnection, extraOptions: [String] = [], trustedHosts: URL? = FilKnownHosts.standard.url, askpass: String = Askpass.helperPath, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.connection = connection
        self.extraOptions = extraOptions
        self.launch = SFTPChannel.Launch(
            executable: SSHCommand.executable,
            arguments: SSHCommand.arguments(for: connection, extraOptions: extraOptions, trustedHosts: trustedHosts),
            environment: SSHCommand.environment(base: environment, askpass: askpass, connectionID: connection.id)
        )
    }

    deinit {
        channel?.terminate()
    }

    // MARK: RemoteFileProvider

    func connect() async throws -> RemotePath {
        let session = SFTPSession(channel: try await activeChannel())
        let home = RemotePath(try await session.realpath("."))
        return RemotePath.resolve(connection.path, from: home)
    }

    nonisolated func list(_ directory: RemotePath) async throws -> [RemoteFile] {
        let session = SFTPSession(channel: try await activeChannel())
        let entries = try await session.readDirectory(directory)

        // Les liens sont résolus en une passe pipelinée : on sait ainsi s'ils mènent à un dossier.
        let links = entries.filter { $0.attributes.isSymbolicLink }
        var targets: [String: SFTPAttributes] = [:]
        if !links.isEmpty {
            let ids = try links.map { link in
                try session.channel.send(.stat) { $0.string(directory.appending(link.filename).value) }
            }
            for (link, id) in zip(links, ids) {
                if case .attributes(let attributes) = try await session.channel.response(for: id) {
                    targets[link.filename] = attributes
                }
            }
        }

        return entries.map { entry in
            let target = targets[entry.filename]
            let attributes = target ?? entry.attributes
            let kind: RemoteFile.Kind
            if entry.attributes.isSymbolicLink, target == nil {
                kind = .link
            } else {
                kind = attributes.isDirectory ? .directory : .file
            }
            return RemoteFile(
                name: entry.filename,
                path: directory.appending(entry.filename),
                kind: kind,
                byteCount: kind == .file ? attributes.size.map { Int64($0) } : nil,
                modifiedAt: attributes.modifiedAt,
                isSymbolicLink: entry.attributes.isSymbolicLink
            )
        }
    }

    nonisolated var canResumeUploads: Bool { true }
    /// Un seul canal multiplexé : plusieurs fichiers à la fois masquent les allers-retours d'ouverture et de fermeture.
    nonisolated var parallelFiles: Int { 4 }

    nonisolated func download(_ file: RemoteFile, to destination: URL, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        let session = SFTPSession(channel: try await activeChannel())
        let handle = try await session.open(file.path, flags: [.read], subject: file.name)
        do {
            let output = try LocalFile.openForWriting(destination, resumingAt: offset)
            defer { try? output.close() }
            var written = offset
            try await session.readAll(handle, from: UInt64(max(0, offset)), subject: file.name) { data in
                try output.write(contentsOf: data)
                written += Int64(data.count)
                progress(written)
            }
            try await session.close(handle, subject: file.name)
        } catch {
            try? await session.close(handle, subject: file.name)
            throw error
        }
    }

    nonisolated func upload(_ source: URL, to destination: RemotePath, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        let session = SFTPSession(channel: try await activeChannel())
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        // Sans troncature en reprise : les `offset` premiers octets restent, on réécrit à partir de là.
        let flags: SFTPOpenFlags = offset > 0 ? [.write, .create] : [.write, .create, .truncate]
        let handle = try await session.open(destination, flags: flags, subject: destination.name)
        do {
            try input.seek(toOffset: UInt64(max(0, offset)))
            try await session.writeAll(handle, from: input, startingAt: UInt64(max(0, offset)), subject: destination.name, progress: progress)
            try await session.close(handle, subject: destination.name)
        } catch {
            try? await session.close(handle, subject: destination.name)
            throw error
        }
    }

    nonisolated func size(of path: RemotePath) async throws -> Int64? {
        let session = SFTPSession(channel: try await activeChannel())
        switch try await session.channel.call(.stat, { $0.string(path.value) }) {
        case .attributes(let attributes):
            return attributes.size.map { Int64($0) }
        case .status(let status) where status.code == SFTPStatus.noSuchFile:
            return nil
        case .status(let status):
            throw SFTPSession.error(for: status, subject: path.name)
        default:
            throw SFTPSession.unexpected
        }
    }

    /// `posix-rename@openssh.com` écrase atomiquement. Les serveurs qui ne le connaissent pas
    /// reçoivent un `RENAME` simple, puis la mise de côté de l'ancien fichier s'il refuse d'écraser.
    nonisolated func move(_ source: RemotePath, to destination: RemotePath) async throws {
        let session = SFTPSession(channel: try await activeChannel())
        let atomic = try await session.channel.call(.extended) { writer in
            writer.string("posix-rename@openssh.com")
            writer.string(source.value)
            writer.string(destination.value)
        }
        if case .status(let status) = atomic, status.code == SFTPStatus.ok { return }
        try await moveReplacing(
            source,
            to: destination,
            rename: { from, to in
                try await session.expectOK(session.channel.call(.rename) { $0.string(from.value); $0.string(to.value) }, subject: to.name)
            },
            exists: { try await self.size(of: $0) != nil },
            remove: { path in try await session.expectOK(session.channel.call(.remove) { $0.string(path.value) }, subject: path.name) }
        )
    }

    nonisolated func makeDirectory(_ path: RemotePath) async throws {
        let session = SFTPSession(channel: try await activeChannel())
        try await session.expectOK(session.channel.call(.mkdir) { $0.string(path.value); $0.attributes(SFTPAttributes()) }, subject: path.name)
    }

    nonisolated func delete(_ file: RemoteFile) async throws {
        let session = SFTPSession(channel: try await activeChannel())
        try await deleteTree(
            file,
            list: { try await self.list($0) },
            removeFile: { path in try await session.expectOK(session.channel.call(.remove) { $0.string(path.value) }, subject: path.name) },
            removeDirectory: { path in try await session.expectOK(session.channel.call(.rmdir) { $0.string(path.value) }, subject: path.name) }
        )
    }

    // MARK: Canal

    /// Simule une coupure : le prochain appel doit rouvrir le canal. Réservé aux tests.
    func dropChannelForTesting() {
        channel?.terminate()
    }

    /// Le canal est rouvert de façon transparente s'il est tombé (veille, coupure réseau).
    private func activeChannel() async throws -> SFTPChannel {
        if let channel, channel.isAlive { return channel }
        if let opening { return try await opening.value }
        let launch = launch
        let connection = connection
        let extraOptions = extraOptions
        let host = connection.resolvedHost
        let port = connection.port
        let task = Task {
            let channel = SFTPChannel(launch: launch) { status, errorOutput in
                SSHCommand.describeExit(status: status, errorOutput: errorOutput, host: host, port: port)
            }
            do {
                _ = try await withTaskCancellationHandler {
                    try await channel.start()
                } onCancel: {
                    channel.terminate()
                }
            } catch ProviderError.hostKeyUnknown(let keys) where keys.isEmpty {
                // Serveur jamais vu : on relève ses clés, sans s'authentifier, pour que l'utilisateur les vérifie.
                throw ProviderError.hostKeyUnknown(try await HostKeyDiscovery.discover(connection: connection, extraOptions: extraOptions))
            } catch ProviderError.hostKeyChanged(let changedHost, _) {
                // Clé changée : on relève celle que le serveur présente maintenant, pour que l'utilisateur
                // puisse la comparer à l'ancienne. Sans elle, le refus reste un refus.
                let presented = (try? await HostKeyDiscovery.discover(connection: connection, extraOptions: extraOptions)) ?? []
                throw ProviderError.hostKeyChanged(changedHost, presented: presented)
            }
            return channel
        }
        opening = task
        defer { opening = nil }
        let channel = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        self.channel = channel
        return channel
    }
}

/// Opérations SFTP sur un canal ouvert, avec traduction des statuts en phrases.
struct SFTPSession: Sendable {
    let channel: SFTPChannel

    func realpath(_ path: String) async throws -> String {
        switch try await channel.call(.realpath, { $0.string(path) }) {
        case .name(let entries) where !entries.isEmpty: return entries[0].filename
        case .status(let status): throw Self.error(for: status, subject: path)
        default: throw Self.unexpected
        }
    }

    func readDirectory(_ directory: RemotePath) async throws -> [SFTPNameEntry] {
        let handle: Data
        switch try await channel.call(.opendir, { $0.string(directory.value) }) {
        case .handle(let value): handle = value
        case .status(let status): throw Self.error(for: status, subject: directory.name)
        default: throw Self.unexpected
        }
        var entries: [SFTPNameEntry] = []
        do {
            reading: while true {
                try Task.checkCancellation()
                switch try await channel.call(.readdir, { $0.string(handle) }) {
                case .name(let batch):
                    entries += batch.filter { $0.filename != "." && $0.filename != ".." }
                case .status(let status) where status.code == SFTPStatus.endOfFile:
                    break reading
                case .status(let status):
                    throw Self.error(for: status, subject: directory.name)
                default:
                    throw Self.unexpected
                }
            }
        } catch {
            try? await close(handle, subject: directory.name)
            throw error
        }
        try? await close(handle, subject: directory.name)
        return entries
    }

    func open(_ path: RemotePath, flags: SFTPOpenFlags, subject: String) async throws -> Data {
        switch try await channel.call(.open, { writer in
            writer.string(path.value)
            writer.uint32(flags.rawValue)
            writer.attributes(SFTPAttributes())
        }) {
        case .handle(let handle): return handle
        case .status(let status): throw Self.error(for: status, subject: subject)
        default: throw Self.unexpected
        }
    }

    func close(_ handle: Data, subject: String) async throws {
        try expectOK(await channel.call(.close) { $0.string(handle) }, subject: subject)
    }

    /// Lit le fichier dans l'ordre à partir de `start`, avec `SFTPProvider.window` lectures en vol.
    func readAll(_ handle: Data, from start: UInt64 = 0, subject: String, consume: (Data) throws -> Void) async throws {
        let block = SFTPProvider.blockSize
        var nextOffset: UInt64 = start
        var inFlight: [(offset: UInt64, length: UInt32, id: UInt32)] = []
        var reachedEnd = false
        defer { channel.abandon(inFlight.map(\.id)) }

        func request(_ offset: UInt64, _ length: UInt32) throws -> UInt32 {
            try channel.send(.read) { writer in
                writer.string(handle)
                writer.uint64(offset)
                writer.uint32(length)
            }
        }

        while true {
            try Task.checkCancellation()
            while !reachedEnd, inFlight.count < SFTPProvider.window {
                inFlight.append((nextOffset, block, try request(nextOffset, block)))
                nextOffset += UInt64(block)
            }
            guard !inFlight.isEmpty else { return }
            let current = inFlight.removeFirst()
            switch try await channel.response(for: current.id) {
            case .data(let data):
                try consume(data)
                // Lecture courte avant la fin : on complète avant de passer au bloc suivant, l'ordre reste juste.
                var offset = current.offset + UInt64(data.count)
                var missing = current.length - UInt32(data.count)
                while missing > 0 {
                    let response = try await channel.response(for: request(offset, missing))
                    guard case .data(let rest) = response, !rest.isEmpty else {
                        if case .status(let status) = response, status.code != SFTPStatus.endOfFile {
                            throw Self.error(for: status, subject: subject)
                        }
                        reachedEnd = true
                        break
                    }
                    try consume(rest)
                    offset += UInt64(rest.count)
                    missing -= UInt32(rest.count)
                }
            case .status(let status) where status.code == SFTPStatus.endOfFile:
                reachedEnd = true
            case .status(let status):
                throw Self.error(for: status, subject: subject)
            default:
                throw Self.unexpected
            }
        }
    }

    /// Écrit le fichier local à partir de `start` (l'entrée est déjà positionnée), avec
    /// `SFTPProvider.window` écritures en vol. La progression compte depuis le début du fichier.
    func writeAll(_ handle: Data, from input: FileHandle, startingAt start: UInt64 = 0, subject: String, progress: ProgressHandler) async throws {
        var offset: UInt64 = start
        var acknowledged = Int64(start)
        var inFlight: [(id: UInt32, length: Int)] = []
        var exhausted = false
        defer { channel.abandon(inFlight.map(\.id)) }

        while true {
            try Task.checkCancellation()
            while !exhausted, inFlight.count < SFTPProvider.window {
                guard let data = try input.read(upToCount: Int(SFTPProvider.blockSize)), !data.isEmpty else {
                    exhausted = true
                    break
                }
                let chunkOffset = offset
                let id = try channel.send(.write) { writer in
                    writer.string(handle)
                    writer.uint64(chunkOffset)
                    writer.string(data)
                }
                inFlight.append((id, data.count))
                offset += UInt64(data.count)
            }
            guard !inFlight.isEmpty else { return }
            let current = inFlight.removeFirst()
            try expectOK(await channel.response(for: current.id), subject: subject)
            acknowledged += Int64(current.length)
            progress(acknowledged)
        }
    }

    func expectOK(_ response: SFTPResponse, subject: String) throws {
        guard case .status(let status) = response else { throw Self.unexpected }
        guard status.code == SFTPStatus.ok else { throw Self.error(for: status, subject: subject) }
    }

    static let unexpected = ProviderError.server("Le serveur a envoyé une réponse SFTP inattendue.")

    static func error(for status: SFTPStatus, subject: String) -> ProviderError {
        switch status.code {
        case SFTPStatus.noSuchFile: .notFound(subject)
        case SFTPStatus.permissionDenied: .accessDenied(subject)
        case SFTPStatus.noConnection, SFTPStatus.connectionLost: .connectionLost
        case SFTPStatus.unsupported: .server("Le serveur ne prend pas en charge cette opération.")
        case SFTPStatus.failure:
            .server(status.message.isEmpty
                ? "Le serveur refuse l'opération sur « \(subject) » : élément déjà présent, dossier non vide ou droits insuffisants."
                : "Le serveur refuse l'opération sur « \(subject) » : \(status.message).")
        default:
            .server("Erreur SFTP \(status.code) sur « \(subject) »\(status.message.isEmpty ? "" : " : \(status.message)").")
        }
    }
}
