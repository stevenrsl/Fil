import Foundation
import Security

/// Relève le certificat qu'un serveur FTPS présente, sans lui confier de mot de passe.
///
/// FTPS explicite commence en clair (`AUTH TLS`) puis passe en TLS sur la même connexion :
/// `URLSessionStreamTask.startSecureConnection()` fait exactement ça, avec les API d'Apple.
/// Dès que le serveur présente son certificat, on le garde et on coupe : rien d'autre n'est envoyé.
enum CertificateReader {
    static let timeout: TimeInterval = 10

    static func readFTPS(host: String, port: Int, implicit: Bool) async throws -> CertificateInfo {
        let collector = Collector()
        let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.streamTask(withHostName: host, port: port)
        task.resume()

        if !implicit {
            _ = try await readReply(task)
            try await task.write(Data("AUTH TLS\r\n".utf8), timeout: timeout)
            let reply = try await readReply(task)
            guard reply.hasPrefix("234") else { throw ProviderError.tlsUnavailable }
        }
        task.startSecureConnection()
        // La poignée de main part à la première lecture ; l'abandon qui la suit est voulu.
        _ = try? await task.readData(ofMinLength: 1, maxLength: 16, timeout: timeout)

        guard let der = collector.der, let info = CertificateInfo(der: der) else { throw ProviderError.tlsUnavailable }
        return info
    }

    /// Une réponse FTP s'arrête à la ligne `ddd ` (espace après le code) ; `ddd-` annonce une suite.
    private static func readReply(_ task: URLSessionStreamTask) async throws -> String {
        var text = ""
        while true {
            let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 4096, timeout: timeout)
            if let data { text += String(decoding: data, as: UTF8.self) }
            if isCompleteReply(text) || atEOF { return text }
        }
    }

    /// Vrai quand `text` se termine par la dernière ligne d'une réponse (`220 prêt\r\n`, ou la fin de `220-…` / `220 …`).
    ///
    /// La fin de ligne se compare en octets : pour Swift, `\r\n` est un seul caractère et
    /// `"a\r\n".hasSuffix("\n")` est faux.
    static func isCompleteReply(_ text: String) -> Bool {
        guard text.utf8.last == 0x0A else { return false }
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        guard let last = lines.last else { return false }
        let bytes = Array(last.utf8)
        return bytes.count >= 4 && bytes[0...2].allSatisfy { $0 >= 0x30 && $0 <= 0x39 } && bytes[3] == 0x20
    }

    private final class Collector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var der: Data? { lock.withLock { stored } }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust,
               let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
                lock.withLock { stored = SecCertificateCopyData(leaf) as Data }
            }
            // On a ce qu'on voulait : aucune donnée ne part vers un serveur qu'on ne connaît pas encore.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Relève les clés d'un serveur SSH qu'on ne connaît pas, **sans s'authentifier** : une connexion
/// d'essai vers un fichier `known_hosts` jetable, avec `PreferredAuthentications=none`.
/// C'est `ssh` lui-même qui négocie : alias, rebond (`ProxyJump`), port et `~/.ssh/config` sont respectés,
/// et la clé relevée est exactement celle qu'il présentera ensuite.
enum HostKeyDiscovery {
    static func discover(connection: RemoteConnection, extraOptions: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [HostKey] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fil-hostkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let knownHosts = folder.appendingPathComponent("known_hosts")
        FileManager.default.createFile(atPath: knownHosts.path, contents: nil)

        let output = await ProcessRunner.run(
            SSHCommand.executable,
            arguments: SSHCommand.discoveryArguments(for: connection, extraOptions: extraOptions, knownHostsFile: knownHosts),
            environment: environment,
            timeout: .seconds(30)
        )
        let text = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
        let keys = text.split(whereSeparator: \.isNewline).compactMap { HostKey(knownHostsLine: String($0)) }
        guard !keys.isEmpty else {
            throw SSHCommand.describeExit(status: output.status, errorOutput: output.errorOutput, host: connection.resolvedHost, port: connection.port)
        }
        return keys
    }
}
