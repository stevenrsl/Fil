import Foundation

/// Un processus `ssh -s … sftp` et le multiplexage des requêtes par identifiant.
/// OpenSSH gère le transport, les clés, l'agent et `known_hosts` ; Fil ne parle que SFTP.
final class SFTPChannel: @unchecked Sendable {
    struct Launch: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private let launch: Launch
    private let describeExit: @Sendable (_ status: Int32, _ errorOutput: String) -> Error
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writer = DispatchQueue(label: "fil.sftp.writer")

    private let lock = NSLock()
    private var buffer = Data()
    private var waiting: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var arrived: [UInt32: SFTPResponse] = [:]
    private var abandoned: Set<UInt32> = []
    private var versionWaiter: CheckedContinuation<UInt32, Error>?
    private var serverVersion: UInt32?
    private var failure: Error?
    private var nextID: UInt32 = 1

    init(launch: Launch, describeExit: @escaping @Sendable (Int32, String) -> Error) {
        self.launch = launch
        self.describeExit = describeExit
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    var isAlive: Bool { lock.withLock { failure == nil } && process.isRunning }

    /// Lance `ssh`, négocie SFTP et renvoie la version du serveur.
    func start() async throws -> UInt32 {
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.receive(data)
            }
        }

        do {
            try process.run()
        } catch {
            throw ProviderError.server("Impossible de lancer ssh : \(error.localizedDescription)")
        }

        // L'erreur standard se lit jusqu'à la fin du processus : c'est elle qui explique un échec.
        let errorHandle = errors.fileHandleForReading
        let process = process
        Thread.detachNewThread { [weak self] in
            let data = errorHandle.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard let self else { return }
            self.fail(with: self.describeExit(process.terminationStatus, text))
        }

        write(SFTPCodec.packet(.initialize, id: nil) { $0.uint32(3) })

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let serverVersion {
                    continuation.resume(returning: serverVersion)
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    versionWaiter = continuation
                }
            }
        }
    }

    /// Envoie une requête sans attendre sa réponse ; renvoie son identifiant.
    func send(_ type: SFTPPacketType, _ body: (inout SFTPWriter) -> Void) throws -> UInt32 {
        let id: UInt32 = try lock.withLock {
            if let failure { throw failure }
            let id = nextID
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            return id
        }
        write(SFTPCodec.packet(type, id: id, body: body))
        return id
    }

    func response(for id: UInt32) async throws -> SFTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let response = arrived.removeValue(forKey: id) {
                    continuation.resume(returning: response)
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    waiting[id] = continuation
                }
            }
        }
    }

    func call(_ type: SFTPPacketType, _ body: (inout SFTPWriter) -> Void) async throws -> SFTPResponse {
        try await response(for: send(type, body))
    }

    /// Réponses dont on n'attend plus rien (transfert annulé avec des lectures en vol).
    func abandon(_ ids: [UInt32]) {
        lock.withLock {
            for id in ids where arrived.removeValue(forKey: id) == nil {
                abandoned.insert(id)
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        fail(with: ProviderError.connectionLost)
    }

    // MARK: Interne

    private func write(_ packet: Data) {
        let handle = input.fileHandleForWriting
        writer.async { [weak self] in
            do {
                try handle.write(contentsOf: packet)
            } catch {
                self?.fail(with: ProviderError.connectionLost)
            }
        }
    }

    private func receive(_ data: Data) {
        var responses: [(UInt32?, SFTPResponse)] = []
        var wireError: Error?
        lock.withLock {
            buffer.append(data)
            do {
                while let payload = try SFTPCodec.nextPacket(from: &buffer) {
                    responses.append(try SFTPCodec.decode(payload))
                }
            } catch {
                wireError = error
            }
        }
        for (id, response) in responses {
            deliver(id: id, response: response)
        }
        if let wireError {
            if process.isRunning { process.terminate() }
            fail(with: Self.describe(wireError))
        }
    }

    private func deliver(id: UInt32?, response: SFTPResponse) {
        lock.withLock {
            guard let id else {
                if case .version(let version) = response {
                    serverVersion = version
                    versionWaiter?.resume(returning: version)
                    versionWaiter = nil
                }
                return
            }
            if abandoned.remove(id) != nil { return }
            if let continuation = waiting.removeValue(forKey: id) {
                continuation.resume(returning: response)
            } else {
                arrived[id] = response
            }
        }
    }

    private func fail(with error: Error) {
        lock.withLock {
            guard failure == nil else { return }
            failure = error
            versionWaiter?.resume(throwing: error)
            versionWaiter = nil
            for continuation in waiting.values { continuation.resume(throwing: error) }
            waiting.removeAll()
            arrived.removeAll()
        }
    }

    static func describe(_ error: Error) -> Error {
        switch error {
        case SFTPWireError.oversized:
            ProviderError.server("Le serveur affiche du texte avant SFTP, souvent un message de ~/.bashrc ou ~/.profile. Il doit rester silencieux pour les sessions non interactives.")
        default:
            ProviderError.server("Le serveur a envoyé une réponse SFTP illisible.")
        }
    }
}
