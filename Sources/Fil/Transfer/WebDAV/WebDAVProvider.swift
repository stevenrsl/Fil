import Foundation
import Security

/// Ce qu'un fournisseur WebDAV dit de sa session d'arrière-plan, pour qu'iOS puisse la retrouver
/// quand il réveille Fil. Aucune implémentation sur macOS : le Mac ne suspend pas Fil.
protocol BackgroundSessionRegistry: Sendable {
    func opened(_ identifier: String)
    func closed(_ identifier: String)
    /// Toutes les nouvelles de la session ont été livrées : iOS peut rendormir Fil.
    func eventsFinished(_ identifier: String)
}

/// WebDAV en HTTPS, kDrive compris. Les chemins de navigation sont relatifs à la racine WebDAV.
final class WebDAVProvider: RemoteFileProvider {
    let connection: RemoteConnection
    let root: URL
    private let rootPath: String
    /// Requêtes courtes : PROPFIND, HEAD, MOVE, MKCOL, DELETE.
    private let session: URLSession
    private let relay: WebDAVSessionRelay
    /// GET et PUT de fichiers. La même session que `session`, sauf avec `background` : une session
    /// d'arrière-plan, qui continue quand iOS suspend Fil (elle n'accepte que des tâches sur fichier).
    private let transferSession: URLSession
    private let transferRelay: WebDAVSessionRelay
    private let background: (any BackgroundSessionRegistry)?

    /// `root` remplace l'URL déduite de la connexion. Réservé aux tests d'intégration.
    init(connection: RemoteConnection, password: String, root: URL? = nil, background: (any BackgroundSessionRegistry)? = nil) {
        self.connection = connection
        let root = root ?? Self.defaultRoot(for: connection)
        self.root = root
        self.rootPath = root.path.removingPercentEncoding ?? root.path
        let user = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = user.isEmpty ? nil : URLCredential(user: user, password: password, persistence: .forSession)
        let pinned = connection.trustedCertificate?.sha256
        let relay = WebDAVSessionRelay(credential: credential, pinnedSHA256: pinned)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        self.relay = relay
        self.session = session

        self.background = background
        if let background {
            // Le mot de passe passe par la réponse au défi d'authentification, jamais par un en-tête :
            // iOS enregistre les requêtes d'une session d'arrière-plan pour les mener à terme sans Fil.
            let transferRelay = WebDAVSessionRelay(credential: credential, pinnedSHA256: pinned, background: background)
            let identifier = BackgroundTransferSession.makeIdentifier()
            self.transferRelay = transferRelay
            self.transferSession = URLSession(configuration: BackgroundTransferSession.configuration(identifier: identifier), delegate: transferRelay, delegateQueue: nil)
            background.opened(identifier)
        } else {
            self.transferRelay = relay
            self.transferSession = session
        }
    }

    deinit {
        session.invalidateAndCancel()
        // Plus aucun transfert ne tient ce fournisseur : sa session d'arrière-plan n'a plus rien à mener.
        if let background, let identifier = transferSession.configuration.identifier {
            transferSession.invalidateAndCancel()
            background.closed(identifier)
        }
    }

    static func defaultRoot(for connection: RemoteConnection) -> URL {
        var host = connection.resolvedHost
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let port = connection.port == 443 ? "" : ":\(connection.port)"
        let path = RemotePath(connection.path).components.map(encode).joined(separator: "/")
        return URL(string: "https://\(host)\(port)" + (path.isEmpty ? "" : "/\(path)"))
            ?? URL(string: "https://invalid.invalid")!
    }

    // MARK: RemoteFileProvider

    func connect() async throws -> RemotePath {
        _ = try await propfind(.root, depth: "0")
        return .root
    }

    func list(_ directory: RemotePath) async throws -> [RemoteFile] {
        let data = try await propfind(directory, depth: "1")
        return try WebDAVListing.parse(data, rootPath: rootPath, directory: directory)
    }

    /// Un PUT repart toujours du début : le protocole n'a pas d'envoi reprenable.
    var canResumeUploads: Bool { false }

    func download(_ file: RemoteFile, to destination: URL, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        var start = offset
        while true {
            var request = makeRequest(url(for: file.path, directory: false), method: "GET")
            if start > 0 { request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
            do {
                let response = try await run(transferSession.downloadTask(with: request), destination: destination, offset: start, progress: progress)
                // 416 : le fichier a changé de taille depuis le début du téléchargement. On recommence.
                if start > 0, (response as? HTTPURLResponse)?.statusCode == 416 {
                    start = 0
                    continue
                }
                try check(response, subject: file.name)
                return
            } catch is WebDAVResumeMismatch {
                start = 0
            }
        }
    }

    func upload(_ source: URL, to destination: RemotePath, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        var request = makeRequest(url(for: destination, directory: false), method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let response = try await run(transferSession.uploadTask(with: request, fromFile: source), destination: nil, progress: progress)
        try check(response, subject: destination.name)
    }

    func size(of path: RemotePath) async throws -> Int64? {
        var head = makeRequest(url(for: path, directory: false), method: "HEAD")
        head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (_, response) = try await send(head)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.server("Le serveur a répondu de façon inattendue.") }
        switch http.statusCode {
        case 200..<300:
            // L'en-tête est la seule source fiable : pour un fichier vide, `expectedContentLength` vaut -1.
            if let header = http.value(forHTTPHeaderField: "Content-Length"), let length = Int64(header) { return length }
            return try await sizeByPropfind(path)
        case 404, 410:
            return nil
        case 405, 501:
            return try await sizeByPropfind(path)
        default:
            try check(response, subject: path.name)
            return nil
        }
    }

    /// Serveur sans `HEAD`, ou muet sur la taille : `PROPFIND` la donne. L'adresse d'un fichier n'a pas de `/` final.
    private func sizeByPropfind(_ path: RemotePath) async throws -> Int64? {
        let data = try await propfind(path, depth: "0", directory: false)
        guard let entry = WebDAVListing.parseEntry(data), let length = entry.length else {
            throw ProviderError.server("Le serveur n'indique pas la taille de « \(path.name) ».")
        }
        return length
    }

    func move(_ source: RemotePath, to destination: RemotePath) async throws {
        var request = makeRequest(url(for: source, directory: false), method: "MOVE")
        request.setValue(url(for: destination, directory: false).absoluteString, forHTTPHeaderField: "Destination")
        // MOVE remplace atomiquement côté serveur : pas de mise de côté à faire ici.
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await send(request)
        try check(response, subject: destination.name)
    }

    func makeDirectory(_ path: RemotePath) async throws {
        let (_, response) = try await send(makeRequest(url(for: path, directory: true), method: "MKCOL"))
        if (response as? HTTPURLResponse)?.statusCode == 405 { throw ProviderError.alreadyExists(path.name) }
        try check(response, subject: path.name)
    }

    func delete(_ file: RemoteFile) async throws {
        // DELETE sur une collection est récursif par définition (RFC 4918, 9.6.1).
        let (_, response) = try await send(makeRequest(url(for: file.path, directory: file.isDirectory), method: "DELETE"))
        try check(response, subject: file.name)
    }

    // MARK: Mécanique

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw translate(error)
        }
    }

    private func run(_ task: URLSessionTask, destination: URL?, offset: Int64 = 0, progress: @escaping ProgressHandler) async throws -> URLResponse {
        do {
            return try await transferRelay.run(task, destination: destination, offset: offset, progress: progress)
        } catch {
            throw translate(error)
        }
    }

    /// Un certificat refusé coupe la requête : l'erreur d'`URLSession` ne dit rien. Le relais, lui, a vu le certificat.
    private func translate(_ error: Error) -> Error {
        guard let presented = relay.takeUntrustedCertificate() ?? transferRelay.takeUntrustedCertificate() else { return error }
        // Approuvé autrefois et plus reconnu : on refuse. Jamais vu : on le montre à l'utilisateur.
        if connection.trustedCertificate != nil { return ProviderError.certificateChanged(host: connection.resolvedHost, presented: presented) }
        return ProviderError.certificateToConfirm(presented)
    }

    private func propfind(_ path: RemotePath, depth: String, directory: Bool = true) async throws -> Data {
        var request = makeRequest(url(for: path, directory: directory), method: "PROPFIND")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
            """.utf8)
        let (data, response) = try await send(request)
        if (response as? HTTPURLResponse)?.statusCode == 405 {
            throw ProviderError.server("Cette adresse ne répond pas comme un serveur WebDAV. Vérifie le chemin de la racine WebDAV.")
        }
        try check(response, subject: path.isRoot ? connection.resolvedHost : path.name)
        return data
    }

    func url(for path: RemotePath, directory: Bool) -> URL {
        var string = root.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        for component in path.components { string += "/" + Self.encode(component) }
        if directory { string += "/" }
        return URL(string: string) ?? root
    }

    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func check(_ response: URLResponse, subject: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Le serveur a répondu de façon inattendue.")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ProviderError.authenticationFailed
        case 403: throw ProviderError.accessDenied(subject)
        case 404, 410: throw ProviderError.notFound(subject)
        case 409: throw ProviderError.server("Le dossier parent de « \(subject) » n'existe pas sur le serveur.")
        case 423: throw ProviderError.server("« \(subject) » est verrouillé par une autre application.")
        case 507: throw ProviderError.server("Il n'y a plus assez d'espace sur le serveur.")
        case 500..<600: throw ProviderError.server("Le serveur rencontre un problème (code \(http.statusCode)). Réessaie dans un instant.")
        default: throw ProviderError.server("Le serveur a répondu avec le code \(http.statusCode) pour « \(subject) ».")
        }
    }

    private static let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? component
    }
}

/// Délégué de session : authentification et progression des transferts.
/// La progression n'arrive qu'au délégué de session, pas à un délégué par tâche.
final class WebDAVSessionRelay: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<URLResponse, Error>
        let destination: URL?
        let offset: Int64
        let progress: ProgressHandler
        var moveError: Error?
    }

    private let credential: URLCredential?
    private let pinnedSHA256: String?
    private let background: (any BackgroundSessionRegistry)?
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var untrusted: CertificateInfo?

    init(credential: URLCredential?, pinnedSHA256: String? = nil, background: (any BackgroundSessionRegistry)? = nil) {
        self.credential = credential
        self.pinnedSHA256 = pinnedSHA256
        self.background = background
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        background?.eventsFinished(identifier)
    }
    #endif

    /// Le dernier certificat refusé, une seule fois.
    func takeUntrustedCertificate() -> CertificateInfo? {
        lock.withLock {
            defer { untrusted = nil }
            return untrusted
        }
    }

    func run(_ task: URLSessionTask, destination: URL?, offset: Int64 = 0, progress: @escaping ProgressHandler) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(continuation: continuation, destination: destination, offset: offset, progress: progress)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func progressHandler(for task: URLSessionTask) -> ProgressHandler? {
        lock.withLock { pending[task.taskIdentifier]?.progress }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Une réponse 206 ne contient que la suite : la progression compte depuis le début du fichier.
        let resumed = (downloadTask.response as? HTTPURLResponse)?.statusCode == 206
        let offset = resumed ? (lock.withLock { pending[downloadTask.taskIdentifier]?.offset } ?? 0) : 0
        progressHandler(for: downloadTask)?(offset + totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressHandler(for: task)?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier temporaire disparaît au retour de cette méthode : on le range tout de suite.
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let entry = lock.withLock({ pending[downloadTask.taskIdentifier] }),
              let destination = entry.destination else { return }
        do {
            if http.statusCode == 206, entry.offset > 0 {
                // La suite arrive : elle n'est valable que si elle commence exactement là où on s'est arrêté.
                guard Self.contentRangeStart(http) == entry.offset else { throw WebDAVResumeMismatch() }
                try Self.append(location, to: destination, after: entry.offset)
            } else {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
            }
        } catch {
            lock.withLock { pending[downloadTask.taskIdentifier]?.moveError = error }
        }
    }

    /// Début de la plage renvoyée : `Content-Range: bytes 1000-1999/2000`.
    static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let digits = value.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int64(digits)
    }

    private static func append(_ source: URL, to destination: URL, after offset: Int64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(offset))
        try output.seek(toOffset: UInt64(offset))
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                entry.continuation.resume(throwing: CancellationError())
            } else {
                entry.continuation.resume(throwing: error)
            }
        } else if let moveError = entry.moveError {
            entry.continuation.resume(throwing: moveError)
        } else if let response = task.response {
            entry.continuation.resume(returning: response)
        } else {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            // Un seul essai : au-delà, le 401 remonte tel quel et devient « identifiant refusé ».
            if challenge.previousFailureCount == 0, let credential {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            var failure: CFError?
            if SecTrustEvaluateWithError(trust, &failure) {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            // macOS ne reconnaît pas ce certificat. Il n'est accepté que s'il est celui que l'utilisateur a approuvé.
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            if let pinnedSHA256, CertificateInfo.sha256Hex(of: der) == pinnedSHA256 {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                lock.withLock { untrusted = CertificateInfo(der: der) }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Le serveur a répondu 206 pour une autre plage que celle demandée : on repart de zéro.
struct WebDAVResumeMismatch: Error {}

/// Session d'arrière-plan des transferts WebDAV : un identifiant par fournisseur, rien de gardé hors d'elle.
enum BackgroundTransferSession {
    static let identifierPrefix = "com.fil.transfers."

    static func makeIdentifier() -> String { identifierPrefix + UUID().uuidString }

    static func configuration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        #if os(iOS)
        // Réveiller Fil à la fin d'un fichier, pour enchaîner le suivant et dire quand tout est fini.
        configuration.sessionSendsLaunchEvents = true
        #endif
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 4
        // Ni cache, ni cookies, ni identifiants enregistrés : comme la session éphémère des requêtes courtes.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
